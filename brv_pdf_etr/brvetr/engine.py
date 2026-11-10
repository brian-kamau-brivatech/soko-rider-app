"""The worker: watches the Input folder, signs each invoice with KRA, writes the stamped PDF."""
import hashlib
import json
import os
import re
import shutil
import threading
import time
import traceback
from datetime import datetime

from . import items as itemreg
from . import kra, licence, taxes
from .db import Db, item_key
from .parser import line_incl, line_tax, parse, tax_code
from .stamp import stamp_pdf
from .vscu import Vscu


class Problem(Exception):
    """A reason the invoice cannot be signed (shown to the user, file goes to Error)."""


class Offline(Exception):
    """The VSCU did not answer: leave the PDF in Input and try again later."""


def file_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def unique_path(folder, name):
    base, ext = os.path.splitext(name)
    p = os.path.join(folder, name)
    i = 2
    while os.path.exists(p):
        p = os.path.join(folder, "%s (%d)%s" % (base, i, ext))
        i += 1
    return p


SIGNED_MARKS = re.compile(r"CU\s*INVOICE\s*NO\.?\s*:?\s*([A-Z]{3}CU\w+/\d+)|Receipt\s*Signature\s*:?\s*[A-Z0-9-]{16}|"
                          r"SCU\s*INFORMATION", re.I)


def already_signed(text):
    """The CU invoice number found if the PDF already carries KRA signing details, else ''."""
    m = SIGNED_MARKS.search(text or "")
    if not m:
        return ""
    return m.group(1) or m.group(0)[:40]


def wait_until_ready(path, tries=20, delay=0.5):
    """The accounting software may still be writing the file: wait until it stops growing."""
    last = -1
    for _ in range(tries):
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as f:
                f.read(1)
        except OSError:
            time.sleep(delay)
            continue
        if size > 0 and size == last:
            return True
        last = size
        time.sleep(delay)
    return False


class Engine:
    def __init__(self, settings, db=None, on_event=None):
        self.s = settings
        self.db = db or Db()
        self.vscu = Vscu(settings, log=self.db.log_call)
        self.on_event = on_event or (lambda kind, msg: None)
        self._stop = threading.Event()
        self._warned = {}
        self._lic_warned = None
        self.licence = None
        self._thread = None
        self._busy = threading.Lock()
        self.status = "Stopped"
        self.offline = ""

    # ------------------------------------------------------------------ control
    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="watcher", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self.status = "Stopped"
        self.on_event("status", self.status)

    @property
    def running(self):
        return bool(self._thread and self._thread.is_alive() and not self._stop.is_set())

    def _loop(self):
        self.status = "Watching"
        self.on_event("status", self.status)
        while not self._stop.is_set():
            try:
                self.scan_once()
            except Exception as e:  # never let the watcher die
                self.on_event("error", "Watcher error: %s" % e)
                traceback.print_exc()
            self._stop.wait(max(1, int(self.s.get("poll_seconds") or 3)))

    # ------------------------------------------------------------------ setup
    def initialise(self):
        res, last = self.vscu.initialise()
        if res.ok or self.vscu.already_installed(res):
            if last is not None:
                self.db.set_next_invoice_no(last + 1)
            elif self.db.get("next_invc_no") is None:
                self.db.set_next_invoice_no(1)
        return res

    # ------------------------------------------------------------------ scanning
    def pending_files(self):
        """PDFs in Input and in its sub-folders (one sub-folder per template, e.g. Input\\Yiwak)."""
        folder = self.s["input_dir"]
        if not os.path.isdir(folder):
            return []
        paths = []
        for d in [folder] + [os.path.join(folder, n) for n in os.listdir(folder)
                             if os.path.isdir(os.path.join(folder, n)) and not n.startswith((".", "~"))]:
            try:
                paths += [os.path.join(d, n) for n in os.listdir(d)
                          if n.lower().endswith(".pdf") and not n.startswith(("~", ".")) and
                          os.path.isfile(os.path.join(d, n))]
            except OSError:
                pass
        paths.sort(key=lambda p: os.path.getmtime(p))
        return paths

    def subfolder(self, path):
        """'Yiwak' for Input\\Yiwak\\x.pdf, '' for Input\\x.pdf."""
        try:
            rel = os.path.relpath(os.path.dirname(os.path.abspath(path)), os.path.abspath(self.s["input_dir"]))
        except ValueError:
            return ""
        return "" if rel in (".", "") or rel.startswith("..") else rel.split(os.sep)[0]

    def forced_template(self, path):
        sub = self.subfolder(path).lower()
        if not sub:
            return None
        return next((t for t in self.s["templates"] if (t.get("folder") or "").strip().lower() == sub), None)

    def _out_dir(self, base, src):
        sub = self.subfolder(src) if src else ""
        d = os.path.join(base, sub) if sub else base
        os.makedirs(d, exist_ok=True)
        return d

    def scan_once(self):
        if not self._busy.acquire(blocking=False):
            return
        try:
            self.s.make_folders()
            if not self.s.ready:
                self.status = "Not set up: open Settings and connect to the VSCU"
                self.on_event("status", self.status)
                return
            # Invoices waiting for the VSCU go first, with their own numbers.
            for row in self.db.waiting():
                self.resend(row["id"])
            if self.db.waiting():
                self.status = "VSCU not answering: invoices are waiting (they keep their numbers)"
                self.on_event("status", self.status)
                return
            files = self.pending_files()
            try:
                licence.touch(self.s)
            except Exception:
                pass
            lic = licence.status(self.s)
            self.licence = lic
            if not lic["ok"]:
                self.status = "NOT SIGNING - %s" % lic["message"]
                self.on_event("status", self.status)
                if files and self._lic_warned != lic["state"]:
                    self._lic_warned = lic["state"]
                    self.on_event("error", "%d PDF(s) wait in Input: %s" % (len(files), lic["message"]))
                return
            self._lic_warned = None
            self.status = "Watching" if not files else "Signing %d invoice(s)..." % len(files)
            self.on_event("status", self.status)
            self.offline = ""
            for path in files:
                if self._stop.is_set():
                    break
                self.process(path)
                if self.db.waiting() or self.offline:
                    break
            if self.offline:
                self.status = "VSCU not answering: %d invoice(s) waiting in Input" % len(self.pending_files())
                self.on_event("status", self.status)
                return
            if files:
                self.status = "Watching"
                self.on_event("status", self.status)
        finally:
            self._busy.release()

    # ------------------------------------------------------------------ one file
    def process(self, path):
        name = os.path.basename(path)
        if not wait_until_ready(path):
            return  # still being written; try next round
        try:
            h = file_hash(path)
            old = self.db.by_hash(h)
            if old and old["status"] == "signed":
                # Same PDF again (re-print): give back the signed copy, no new KRA invoice.
                try:
                    out = self._write_output(path, old, name)
                except Exception as e:
                    if self._warned.get(path) != str(e):
                        self._warned[path] = str(e)
                        self.on_event("error", "%s is signed at KRA (CU %s/%s) but the stamped copy could not be "
                                      "saved: %s. Trying again." % (name, old["sdc_id"], old["invc_no"], e))
                    return
                self._warned.pop(path, None)
                self._archive(path)
                self.on_event("info", "%s was already signed (CU %s/%s). Signed copy written again: %s"
                              % (name, old["sdc_id"], old["invc_no"], os.path.basename(out)))
                return
            if old and old["status"] == "waiting":
                return
            if old:  # failed before: try again from scratch
                self.db.delete(old["id"])
            parsed = parse(path, self.s["templates"], own_tin=self.s["tin"], force=self.forced_template(path))
            self._sign_new(path, name, h, parsed)
        except Offline as o:
            self.offline = str(o)
            self.on_event("waiting", "%s: %s It stays in Input and is tried again automatically." % (name, o))
        except Problem as p:
            self._fail(path, name, str(p))
        except ValueError as e:
            self._fail(path, name, str(e))
        except Exception as e:
            traceback.print_exc()
            self._fail(path, name, "Unexpected error: %s" % e)

    def check(self, parsed):
        """Everything that can be checked before talking to KRA. Returns [(line, tax, total incl VAT)]."""
        tpl = parsed["template"]
        own = (self.s.get("tin") or "").upper()
        if parsed.get("seller_pin") and own and parsed["seller_pin"] != own:
            raise Problem("This invoice is from KRA PIN %s, but this app signs for %s. It was not signed."
                          % (parsed["seller_pin"], own))
        if parsed.get("ocr") and parsed.get("total") is None:
            raise Problem("This PDF was read with OCR (it has no text), so the invoice total must be read to check "
                          "every amount. Add the TOTAL AMOUNT row to the template.")
        if not parsed["lines"]:
            raise Problem("No item lines were found. Check the template's 'item line' pattern with Test a PDF.")
        problems, _notes = taxes.resolve(parsed, tpl, taxes.parse_rules(self.s.get("tax_rules", "")), self.known_tax)
        if problems:
            raise Problem(problems[0])
        out = []
        for i, ln in enumerate(parsed["lines"], 1):
            if ln["amount"] < 0 or ln["qty"] < 0:
                raise Problem("Line %d (%s) has a negative amount (discount line). Put discounts inside the item "
                              "prices, or issue a credit note." % (i, ln["desc"]))
            if ln["qty"] == 0:
                raise Problem("Line %d (%s) has quantity 0." % (i, ln["desc"]))
            if not ln["desc"]:
                raise Problem("Line %d has no description." % i)
            tax = line_tax(tpl, ln)
            rate = kra.TAX_RATES.get(tax, 0.0)
            total = ln["amount"] if line_incl(tpl, ln) else ln["amount"] * (100 + rate) / 100
            out.append((ln, tax, kra.r2(total)))
        total = kra.r2(sum(t for _, _, t in out))
        printed = parsed["total"]
        left_out = kra.r2(sum(a for _, a in parsed.get("excluded") or []))
        if printed is not None and abs(abs(printed) - left_out - total) > max(1.0, abs(printed) * 0.001):
            extra = (" (plus %.2f service charge / levy not sent to KRA)" % left_out) if left_out else ""
            raise Problem("The item lines add up to %.2f%s but the invoice total is %.2f. Some lines were not read "
                          "correctly: check the template with Test a PDF." % (total, extra, printed))
        if not (parsed["invoice_no"] or "").strip():
            raise Problem("The invoice number was not found. Check the template's 'invoice number' pattern.")
        return out

    def known_tax(self, ln):
        """Tax group from the item register (item code first, then name)."""
        row = itemreg.find(self.db, ln.get("desc"), ln.get("code"))
        if not row:
            return None
        if row["registered"] or row["source"] in ("manual", "import"):
            return row["tax"]
        return None

    def currency(self, parsed):
        """(currency, rate to KES) for this invoice."""
        tpl = parsed["template"]
        cur = (tpl.get("currency") or "KES").upper()
        if cur == "INVOICE":
            cur = parsed.get("currency") or ""
            if not cur:
                raise Problem("The currency was not found on the invoice. Check the template's CURRENCY row, or set "
                              "the template currency.")
        if cur == "KES":
            return "KES", 1.0
        rate = parsed.get("rate")
        if not rate or rate <= 0:
            rate = self.s.rates().get(cur)
        if not rate or rate <= 0:
            raise Problem("No exchange rate for %s. Enter it in Settings (e.g. %s=129.00), or read the rate "
                          "printed on the invoice (EXCHANGE RATE row)." % (cur, cur))
        return cur, float(rate)

    def _lines(self, parsed, rate=1.0):
        tpl = parsed["template"]
        lines = []
        for ln, tax, total in self.check(parsed):
            total = kra.r2(total * rate)  # KRA amounts are in KES
            disc = float(ln.get("discount") or 0)
            if disc and not line_incl(tpl, ln):
                disc = disc * (100 + kra.TAX_RATES.get(tax, 0.0)) / 100
            disc = kra.r2(disc * rate)
            item = self._item(ln["desc"], tax, tpl, (total + disc) / ln["qty"], ln.get("code") or "")
            lines.append(kra.Line(item["item_cd"], item["cls_cd"], ln["desc"], item["pkg_unit"], item["qty_unit"],
                                  tax, ln["qty"], total / ln["qty"], total=total, discount=disc))
        return lines

    def _item(self, desc, tax, tpl, price, code=""):
        """Item code for this description; registered at KRA the first time it is seen."""
        row = itemreg.find(self.db, desc, code)
        cls_cd = (tpl.get("item_class") or self.s.get("item_class") or "").strip()
        if row and row["registered"] and row["tax"] == tax:
            return dict(row)
        if row and not row["cls_cd"]:
            row = dict(row)
            row["cls_cd"] = cls_cd
            if not cls_cd:
                raise Problem("Item '%s' has no KRA item classification code. Set it in Items or Settings." % desc)
        if not cls_cd and not row:
            raise Problem("Set the KRA item classification code (Settings, or the template) so new items "
                          "like '%s' can be registered." % desc)
        if row:
            item = dict(row)
            item["tax"] = tax
        else:
            seq = self.db.next_item_seq()
            item = {"key": item_key(desc), "name": desc[:200], "cls_cd": cls_cd, "tax": tax, "sku": code,
                    "source": "auto", "origin": "KE", "updated_at": datetime.now().isoformat(timespec="seconds"),
                    "qty_unit": tpl.get("qty_unit") or "U", "pkg_unit": tpl.get("pkg_unit") or "NT",
                    "item_type": tpl.get("item_type") or "2", "price": kra.r2(price),
                    "item_cd": kra.make_item_code("KE", tpl.get("item_type") or "2", tpl.get("pkg_unit") or "NT",
                                                  tpl.get("qty_unit") or "U", seq)}
            item["id"] = self.db.insert("items", {k: item[k] for k in
                                                  ("key", "name", "item_cd", "cls_cd", "tax", "qty_unit",
                                                   "pkg_unit", "item_type", "price", "sku", "source", "origin",
                                                   "updated_at")})
        res = self.vscu.save_item(item)
        if res.no_answer:
            raise Offline(res.message)
        self.db.update("items", item["id"], {"registered": 1 if res.ok else 0, "tax": tax,
                                             "reg_error": "" if res.ok else res.message})
        if not res.ok:
            raise Problem("KRA did not accept the item '%s': %s" % (desc, res.message))
        item["registered"] = 1
        return item

    def register_item(self, iid):
        """Send one item of the register to KRA (items/saveItems)."""
        row = self.db.item_by_id(iid)
        item = dict(row)
        item["cls_cd"] = item["cls_cd"] or (self.s.get("item_class") or "")
        res = self.vscu.save_item(item)
        if not res.no_answer:
            self.db.update("items", iid, {"registered": 1 if res.ok else 0, "cls_cd": item["cls_cd"],
                                          "reg_error": "" if res.ok else res.message})
        return res

    def _sign_new(self, path, name, h, parsed):
        tpl = parsed["template"]
        signed_by = already_signed(parsed.get("text") or "")
        if signed_by:
            raise Problem("This PDF is already signed by a KRA device (%s). It was not signed again, so the sale is "
                          "not reported twice." % signed_by)
        trd = (parsed["invoice_no"] or "").strip()
        if not trd:
            raise Problem("The invoice number was not found. Check the template's 'invoice number' pattern.")
        credit = parsed["credit_note"]
        if not credit:
            prev = self.db.signed_by_trd(trd)
            if prev:
                raise Problem("Invoice %s was already signed (CU %s/%s) from a different PDF. A changed invoice "
                              "needs a credit note, then a new invoice." % (trd, prev["sdc_id"], prev["invc_no"]))
        org = 0
        if credit:
            ref = (parsed["original_invoice"] or "").strip()
            orig = self.db.signed_by_trd(ref) if ref else None
            if not orig:
                raise Problem("Credit note: the original invoice %s was not found among invoices signed by this "
                              "app." % (ref or "(number not found on the PDF)"))
            org = orig["invc_no"]
            done = self.db.con.execute("SELECT COALESCE(SUM(tot_amt_fc), 0) FROM invoices WHERE kind='R' AND "
                                       "status IN ('signed','waiting') AND org_invc_no=?", (org,)).fetchone()[0]
            this = kra.r2(sum(t for _, _, t in self.check(parsed)))
            orig_total = orig["tot_amt_fc"] if orig["tot_amt_fc"] is not None else orig["tot_amt"]
            if orig_total is not None and done + this > orig_total + 1:
                raise Problem("Credit note: invoice %s (KRA %s) totals %.2f and %.2f was already credited; this credit "
                              "note (%.2f) would credit more than the invoice." % (ref, org, orig_total, done, this))
        self.check(parsed)
        cur, rate = self.currency(parsed)
        lines = self._lines(parsed, rate)
        now = datetime.now()
        invc_no = self.db.next_invoice_no()
        payload = kra.build_sale_payload(
            self.s["tin"], self.s["bhf_id"], invc_no, trd, lines, tpl.get("payment") or "01", now,
            credit_note=credit, org_invc_no=org, refund_reason=tpl.get("refund_reason") or "06",
            cust_tin=parsed["customer_pin"], cust_nm=parsed["customer_name"],
            user=self.s.get("user_name") or "BRV PDF ETR", incl_vat=bool(self.s.get("send_incl_vat", True)))
        rid = self.db.insert("invoices", {
            "file_name": name, "file_hash": h, "template": tpl.get("name"), "trd_invc_no": trd, "invc_no": invc_no,
            "kind": "R" if credit else "S", "org_invc_no": org, "cust_nm": payload["custNm"],
            "cust_tin": payload["custTin"], "tot_taxbl": payload["totTaxblAmt"], "tot_tax": payload["totTaxAmt"],
            "tot_amt": payload["totAmt"], "item_cnt": len(lines), "status": "waiting",
            "currency": cur, "rate": rate, "tot_amt_fc": kra.r2(sum(t for _, _, t in self.check(parsed))),
            "excluded": kra.r2(sum(a for _, a in parsed.get("excluded") or [])),
            "payload": json.dumps(payload), "created_at": now.isoformat(timespec="seconds"), "input_path": path})
        self._send(rid)

    def resend(self, rid):
        self._send(rid)

    def _send(self, rid, depth=0):
        row = self.db.invoice(rid)
        payload = json.loads(row["payload"])
        res = self.vscu.save_sale(payload)
        name = row["file_name"]
        if res.ok:
            d = res.data
            v = lambda k: "" if d.get(k) is None else str(d.get(k))
            signed_at = datetime.now()
            self.db.update("invoices", rid, {
                "status": "signed", "error": "", "response": json.dumps(res.raw),
                "rcpt_no": int(v("rcptNo") or v("curRcptNo") or 0) or None,
                "tot_rcpt_no": int(v("totRcptNo") or 0) or None,
                "intrl_data": v("intrlData"), "rcpt_sign": v("rcptSign"),
                "sdc_id": v("sdcId") or self.s.get("sdc_id"), "mrc_no": v("mrcNo") or self.s.get("mrc_no"),
                "sdc_date": v("vsdcRcptPbctDate") or v("sdcDateTime") or kra.etims_dt(signed_at),
                "signed_at": signed_at.isoformat(timespec="seconds")})
            self.db.set_next_invoice_no(payload["invcNo"] + 1)
            if v("sdcId") and not self.s.get("sdc_id"):
                self.s["sdc_id"] = v("sdcId")
                self.s.save()
            row = self.db.invoice(rid)
            src = row["input_path"]
            if src and os.path.exists(src):
                try:
                    out = self._write_output(src, row, name)
                except Exception as e:
                    # Already signed at KRA: keep the PDF in Input; the next round stamps it (no new KRA invoice).
                    self.on_event("error", "%s is signed at KRA (CU %s/%s) but the stamped copy could not be saved: %s. "
                                  "It stays in Input and is stamped again automatically."
                                  % (name, row["sdc_id"], row["invc_no"], e))
                    return
                self._archive(src)
                self.on_event("signed", "%s signed: CU %s/%s, total %.2f -> %s"
                              % (name, row["sdc_id"], row["invc_no"], row["tot_amt"], os.path.basename(out)))
            else:
                self.on_event("signed", "%s signed (CU %s/%s), but the original PDF is gone, so no stamped copy "
                              "was made." % (name, row["sdc_id"], row["invc_no"]))
            return
        if res.no_answer:
            self.db.update("invoices", rid, {"error": res.message})
            self.on_event("waiting", "%s: %s It will be sent again automatically with the same number." % (name, res.message))
            return
        exp = kra.expected_invoice_no(res.msg)
        if exp and depth == 0 and exp != payload["invcNo"]:
            # The VSCU expects another number (e.g. another till used some): follow it once.
            self.db.force_next_invoice_no(exp)
            payload["invcNo"] = exp
            self.db.update("invoices", rid, {"invc_no": exp, "payload": json.dumps(payload)})
            return self._send(rid, depth + 1)
        self.db.update("invoices", rid, {"status": "failed", "error": res.message, "response": json.dumps(res.raw)})
        src = row["input_path"]
        if src and os.path.exists(src):
            self._fail(src, name, "KRA refused the invoice: %s" % res.message, record=False)
        else:
            self.on_event("error", "%s: KRA refused the invoice: %s" % (name, res.message))

    # ------------------------------------------------------------------ files
    def _write_output(self, src, row, name):
        tpl = next((t for t in self.s["templates"] if t.get("name") == row["template"]), self.s["templates"][0])
        base, ext = os.path.splitext(name)
        out = unique_path(self._out_dir(self.s["output_dir"], src), base + (self.s.get("output_suffix") or "") + ext)
        info = {
            "sdc_id": row["sdc_id"], "invc_no": row["invc_no"], "rcpt_no": row["rcpt_no"],
            "tot_rcpt_no": row["tot_rcpt_no"], "intrl_data": row["intrl_data"], "rcpt_sign": row["rcpt_sign"],
            "credit": row["kind"] == "R",
            "currency": row["currency"] or "KES", "rate": row["rate"] or 1,
            "when": datetime.fromisoformat(row["created_at"]),
            "url": kra.receipt_url(self.s["tin"], self.s["bhf_id"], row["rcpt_sign"]),
        }
        stamp_pdf(src, out, info, tpl["stamp"])
        self.db.update("invoices", row["id"], {"output_path": out})
        return out

    def _archive(self, src):
        dst = unique_path(self.s["archive_dir"], datetime.now().strftime("%Y%m%d-%H%M%S ") + os.path.basename(src))
        try:
            shutil.move(src, dst)
        except OSError:
            pass

    def _fail(self, src, name, reason, record=True):
        dst = unique_path(self._out_dir(self.s["error_dir"], src), name)
        try:
            shutil.move(src, dst)
            with open(os.path.splitext(dst)[0] + " - REASON.txt", "w", encoding="utf-8") as f:
                f.write("%s\n\n%s\n\nFix the problem, then put the PDF back in the Input folder.\n"
                        % (datetime.now().strftime("%d/%m/%Y %H:%M"), reason))
        except OSError:
            pass
        if record:
            try:
                self.db.insert("invoices", {"file_name": name, "status": "failed", "error": reason,
                                            "created_at": datetime.now().isoformat(timespec="seconds")})
            except Exception:
                pass
        self.on_event("error", "%s: %s" % (name, reason))
