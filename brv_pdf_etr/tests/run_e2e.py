import copy, os, shutil, sys, time
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests import mock_vscu
from brvetr.config import Settings, DEFAULT_TEMPLATE
from brvetr.db import Db
from brvetr.engine import Engine

work = sys.argv[1]
for d in ("Input", "Output", "Error", "Archive"):
    shutil.rmtree(os.path.join(work, d), ignore_errors=True)
for f in ("settings.json", "t.db", "t.db-wal", "t.db-shm"):
    try: os.remove(os.path.join(work, f))
    except OSError: pass
srv = mock_vscu.serve(18088)
s = Settings(os.path.join(work, "settings.json"))
s.data.update({"vscu_url": "http://127.0.0.1:18088", "tin": "P051111111A", "bhf_id": "00", "serial": "DEV123",
               "item_class": "5020230500",
               "input_dir": os.path.join(work, "Input"), "output_dir": os.path.join(work, "Output"),
               "error_dir": os.path.join(work, "Error"), "archive_dir": os.path.join(work, "Archive")})
qb = copy.deepcopy(DEFAULT_TEMPLATE); qb.update({"name": "Mtaani Supplies (QuickBooks)", "match": "Mtaani Supplies", "prices_include_vat": False})
qb["stamp"] = {"page": "last", "anchor": "bottom-right", "x_mm": 12, "y_mm": 30, "width_mm": 78}
sage = copy.deepcopy(DEFAULT_TEMPLATE); sage.update({"name": "Rift Valley Agro (Sage)", "match": "Rift Valley Agro",
    "line": r"^(?P<code>[A-Z]{3}\d{2})\s+(?P<desc>.+?)\s+(?P<qty>\d+(?:\.\d+)?)\s+(?P<price>[\d,]+\.\d{2})\s+(?P<tax>\d{1,2}%)\s+(?P<amount>[\d,]+\.\d{2})$",
    "tax_map": {"16%": "B", "0%": "C"}})
sage["stamp"] = {"page": "last", "anchor": "auto", "x_mm": 10, "y_mm": 10, "width_mm": 70}
s["templates"] = [qb, sage, copy.deepcopy(DEFAULT_TEMPLATE)]
# A throw-away licence key pair for the test (the real BRV private key is never in the code).
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as _S
from brvetr import licence as LIC, secure as SEC
_tk = Ed25519PrivateKey.generate()
LIC.PUBLIC_KEY = _tk.public_key().public_bytes(_S.Encoding.Raw, _S.PublicFormat.Raw)
s["licence"], _ = LIC.make(_tk, SEC.machine_code(), 30, 1)
s.save()
events = []
eng = Engine(s, Db(os.path.join(work, "t.db")), on_event=lambda k, m: (events.append((k, m)), print("  [%s] %s" % (k, m))))
print("init:", eng.initialise().message, "| next invoice no:", eng.db.next_invoice_no())
s.make_folders()
samples = os.path.join(work, "samples")
def drop(name, as_name=None):
    shutil.copy(os.path.join(samples, name), os.path.join(s["input_dir"], as_name or name))

print("\n1) two invoices")
drop("QB Invoice 1045.pdf"); drop("Sage SI-000233.pdf"); eng.scan_once()
print("\n2) same PDF printed again (reprint)")
drop("QB Invoice 1045.pdf", "QB Invoice 1045 reprint.pdf"); eng.scan_once()
print("\n3) credit note")
drop("QB Credit CN-1045.pdf"); eng.scan_once()
print("\n4) VSCU offline -> waits, keeps number; then back online")
mock_vscu.STATE["offline"] = True
from tests.make_samples import qb_style
qb_style(os.path.join(s["input_dir"], "QB Invoice 1046.pdf"), inv="1046", items=[("Paint 4L", 3, 1450.0)])
eng.scan_once()
print("   waiting:", [(r["file_name"], r["invc_no"]) for r in eng.db.waiting()])
mock_vscu.STATE["offline"] = False
eng.scan_once()
print("\n4b) VSCU offline at the sale itself (item already known)")
mock_vscu.STATE["offline"] = False
qb_style(os.path.join(s["input_dir"], "QB Invoice 1046b.pdf"), inv="1046b", items=[("Paint 4L", 2, 1450.0)])
# register Paint first, then go offline only for the sale
eng.scan_once()
mock_vscu.STATE["offline"] = True
qb_style(os.path.join(s["input_dir"], "QB Invoice 1046c.pdf"), inv="1046c", items=[("Paint 4L", 1, 1450.0)])
eng.scan_once()
print("   waiting:", [(r["file_name"], r["invc_no"]) for r in eng.db.waiting()], "| input:", os.listdir(s["input_dir"]))
mock_vscu.STATE["offline"] = False
eng.scan_once()
print("   waiting after:", eng.db.waiting())
print("\n5) another till used invoice numbers -> VSCU expects a higher number")
mock_vscu.STATE["next"] += 3
qb_style(os.path.join(s["input_dir"], "QB Invoice 1047.pdf"), inv="1047", items=[("Paint 4L", 1, 1450.0)])
eng.scan_once()
print("\n6) unreadable lines -> totals mismatch -> Error folder")
qb_style(os.path.join(s["input_dir"], "QB Invoice 1048.pdf"), inv="1048", items=[("Bolt M10 x 50", 3, 25.0), ("Washer pack", 2, 40.0)])
import pdfplumber  # simulate a line the template cannot read: remove decimals from one amount
from pypdf import PdfReader
from reportlab.pdfgen import canvas as _c
p = os.path.join(s["input_dir"], "QB Invoice 1048.pdf"); os.remove(p)
from reportlab.lib.pagesizes import A4
c = _c.Canvas(p, pagesize=A4); w, h = A4
for i, t in enumerate(["INVOICE", "Mtaani Supplies Ltd", "Invoice #: 1048", "Bill To:", "Kamau Hardware Ltd",
                       "Description Qty Rate Amount", "Bolt M10 x 50 3 25.00 75.00", "Washer pack 2 40 80",
                       "Subtotal 155.00", "VAT 16% 24.80", "Total KES 179.80"]):
    c.drawString(40, h - 60 - i * 16, t)
c.save()
eng.scan_once()
print("\n7) designer template (hotel folio signed from its totals) + its credit note")
from tests.make_samples import hotel_style
from brvetr import visual as V
smp = os.path.join(samples, "Lodge 95487.pdf")
hotel_style(smp, pin="P051111111A")
doc = V.Doc(smp)
def R(key, typ, **kw):
    h = V.find_all(doc, key)[0]; r = V.new_row(key, typ, pos=list(h["box"]), page=h["page"]); r.update(kw); return r
lodge = copy.deepcopy(DEFAULT_TEMPLATE)
lodge.update({"kind": "visual", "name": "Ngulia Lodge", "fields": [
    R("Currency : KSH", "DOCUMENT IDENTIFIER"), R("PIN No", "DOCUMENT TIN"), R("INVOICE. No", "INVOICE NO"),
    R("CUST PIN", "CUSTOMER TIN"), R("NETT:", "NET TAXABLE"), R("VAT:", "VAT"), R("Service Charge", "SERVICE CHARGE"),
    R("Catering Levy", "CATERING LEVY"), R("N Non VAT", "NON TAXABLE"), R("Invoice Total", "TOTAL AMOUNT"),
    dict(V.new_row("", "CUSTOMER NAME"), **{"from": "BOX", "pos": [60, 115, 200, 128], "page": 0}),
    V.new_row("CREDIT NOTE", "CREDIT NOTE IDENTIFIER"), dict(R("INVOICE. No", "ORIGINAL INVOICE NO"), key="Original Invoice")]})
s["templates"] = [lodge] + s["templates"]
s.save()
s.load()
shutil.copy(smp, os.path.join(s["input_dir"], "Lodge 95487.pdf"))
eng.scan_once()
hotel_style(os.path.join(s["input_dir"], "Lodge CN.pdf"), inv="CN95487", credit=True, pin="P051111111A")
eng.scan_once()
hotel_style(os.path.join(s["input_dir"], "Other seller.pdf"), inv="777", pin="P000593855D")
eng.scan_once()

print("\n8) VAT-free items (milk): no VAT column on the invoice, only a VAT total")
from tests.make_samples import shop_style
shop_style(os.path.join(samples, "duka.pdf"), "D-1", [("Fresh milk 500ml", 4, 60.0)])
ddoc = V.Doc(os.path.join(samples, "duka.pdf"))
def D(key, typ, **kw):
    h = V.find_all(ddoc, key)[0]; r = V.new_row(key, typ, pos=list(h["box"]), page=h["page"]); r.update(kw); return r
duka = copy.deepcopy(DEFAULT_TEMPLATE)
duka.update({"kind": "visual", "name": "Duka Mart", "default_tax": "AUTO", "free_code": "C", "prices_include_vat": True,
             "fields": [D("DUKA MART LTD", "DOCUMENT IDENTIFIER"), D("Receipt No", "INVOICE NO"),
                        D("Item", "LIST ITEM START"), D("Total VAT", "LIST ITEM END"), D("Item", "COLUMN DESCRIPTION"),
                        D("Qty", "COLUMN QTY"), D("Price", "COLUMN PRICE"), D("Amount", "COLUMN AMOUNT"),
                        D("Total VAT", "VAT"), D("TOTAL", "TOTAL AMOUNT", case=False)]})
duka["fields"][-1]["key"] = "TOTAL"
s["templates"] = [duka] + s["templates"]
s.save(); s.load()
shop_style(os.path.join(s["input_dir"], "Duka milk only.pdf"), "D-101", [("Fresh milk 500ml", 4, 60.0), ("Long life milk 1L", 2, 140.0)])
eng.scan_once()
shop_style(os.path.join(s["input_dir"], "Duka mixed no rule.pdf"), "D-102", [("Eggs tray 30", 1, 450.0), ("Bar soap 800g", 1, 232.0)], vat_items=("Bar soap 800g",))
eng.scan_once()
s["tax_rules"] = "milk=C, eggs=A"; s.save()
shop_style(os.path.join(s["input_dir"], "Duka mixed.pdf"), "D-103", [("Fresh milk 500ml", 2, 60.0), ("Bar soap 800g", 1, 232.0)], vat_items=("Bar soap 800g",))
eng.scan_once()
shop_style(os.path.join(s["input_dir"], "Duka all vat.pdf"), "D-104", [("Bar soap 800g", 3, 232.0)], vat_items=("Bar soap 800g",))
eng.scan_once()
s["tax_rules"] = ""; s.save()
shop_style(os.path.join(s["input_dir"], "Duka mixed remembered.pdf"), "D-105", [("Long life milk 1L", 1, 140.0), ("Bar soap 800g", 1, 232.0)], vat_items=("Bar soap 800g",))
eng.scan_once()

print("\n9) licence ended -> PDFs wait in Input; renewed -> signed")
good_lic = s["licence"]
from datetime import date, timedelta
s["licence"], _ = LIC.make(_tk, SEC.machine_code(), 5, 2, issued=date.today() - timedelta(days=10)); s.save()
shop_style(os.path.join(s["input_dir"], "Duka after expiry.pdf"), "D-200", [("Bar soap 800g", 1, 232.0)], vat_items=("Bar soap 800g",))
eng.scan_once()
lic_wait = os.listdir(s["input_dir"])
print("   input while expired:", lic_wait, "|", eng.status)
s["licence"] = good_lic; s.save()
eng.scan_once()

print("\n10) item register + Excel upload: item code column and tax group from the list")
from brvetr import items as IT
xl = os.path.join(work, "items.xlsx")
IT.write_template(xl)
rows, errs = IT.read_file(xl, "5020230500")
for it in rows:
    IT.upsert(eng.db, it, "import")
bad_xl = os.path.join(work, "bad.xlsx")
from openpyxl import load_workbook
wb = load_workbook(xl); ws = wb["Items"]; ws["C3"] = "Z"; ws["B4"] = ""; wb.save(bad_xl)
_, bad_errs = IT.read_file(bad_xl)
print("   imported:", len(rows), "errors in good file:", errs, "| bad file errors:", bad_errs)
# eggs are A (exempt) in the list: the mixed invoice that failed before now signs without any rule
s["tax_rules"] = ""; s.save()
shop_style(os.path.join(s["input_dir"], "Duka eggs.pdf"), "D-201", [("Eggs tray 30", 1, 450.0), ("Bar soap 800g", 1, 232.0)], vat_items=("Bar soap 800g",))
eng.scan_once()

print("\n11) USD invoice: converted to KES at the rate in Settings")
s["rates"] = "USD=130.00"
usd = copy.deepcopy(duka); usd["name"] = "Duka USD"; usd["currency"] = "USD"
usd["fields"] = [dict(f) for f in duka["fields"]]
usd["fields"][0] = dict(usd["fields"][0], key="DUKA MART LTD")
s["templates"] = [usd] + [t for t in s["templates"] if t["name"] != "Duka Mart"]
s.save(); s.load()
shop_style(os.path.join(s["input_dir"], "Duka USD.pdf"), "D-300", [("Bar soap 800g", 2, 10.0)], vat_items=("Bar soap 800g",))
eng.scan_once()

print("\n12) reports")
from brvetr import reports as REP
rd = REP.rows(eng.db, "2000-01-01", "2100-01-01")
REP.export_xlsx(os.path.join(work, "report.xlsx"), rd, "2000-01-01", "2100-01-01", "TEST", "All")
REP.export_pdf(os.path.join(work, "report.pdf"), rd, "2000-01-01", "2100-01-01", "TEST", "All")
rsum = REP.summary(rd)
print("   documents:", len(rd), "net to KRA:", rsum["total"], "VAT:", rsum["vat"])

print("\n13) a PDF that already carries KRA CU information is refused")
import shutil as _sh
_sh.copy(os.path.join(s["output_dir"], "Duka mixed.pdf"), os.path.join(s["input_dir"], "Signed elsewhere.pdf"))
from pypdf import PdfReader as _PR, PdfWriter as _PW
_w = _PW(); _w.append(_PR(os.path.join(s["input_dir"], "Signed elsewhere.pdf"))); _w.add_metadata({"/Producer": "x"})
_w.write(os.path.join(s["input_dir"], "Signed elsewhere.pdf"))  # different bytes, same text
eng.scan_once()

print("\n14) KRA box under a text: follows 'Invoice Total' on short and long invoices")
from brvetr import stamp as STP
from datetime import datetime as _dt
pos_ok = []
for nm, lines_ in (("short", None), ("long", [("1%d/05" % (i % 10), "A", "Room night %d" % i, 1250.0, None) for i in range(12)])):
    srcp = os.path.join(work, "pos_%s.pdf" % nm); outp = os.path.join(work, "pos_%s_out.pdf" % nm)
    hotel_style(srcp, lines=lines_)
    STP.stamp_pdf(srcp, outp, {"sdc_id": "KRACU1", "invc_no": 1, "rcpt_no": 1, "tot_rcpt_no": 1, "intrl_data": "A" * 26,
                               "rcpt_sign": "B" * 16, "when": _dt.now(), "credit": False, "url": "https://x"},
                  {"page": "last", "anchor": "text", "anchor_text": "Invoice Total", "x_mm": -60, "y_mm": 8,
                   "style": "box", "width_mm": 75})
    od = V.Doc(outp)
    tot = V.find_all(od, "Invoice Total")[-1]["box"]; box = V.find_all(od, "SCU INFORMATION")[-1]["box"]
    gap_mm = (box[1] - tot[1]) / (72 / 25.4)
    pos_ok.append(5 < gap_mm < 14)
    print("   %s invoice: KRA box title %.1f mm below 'Invoice Total'" % (nm, gap_mm))

print("\n15) item table No,TAX,ItemDescription,Qty,UnitPrice,Tax,DiscountRt,DiscountAmt[,Amount] + document types")
from tests.make_samples import detailed_style
def wholesale_tpl(pdf, doc_type, with_amount=True, col_list=None):
    dd = V.Doc(pdf)
    def W(key, typ, n=0, **kw):
        hh = V.find_all(dd, key, False)[n]; r = V.new_row(key, typ, pos=list(hh["box"]), page=hh["page"]); r.update(kw); return r
    names = V.parse_column_list(col_list or ("/No,TAX,ItemDescription,Qty,UnitPrice,Tax,DiscountRt,DiscountAmt" +
                                             (",Amount" if with_amount else "")))
    pi, li, got = V.find_header(dd, names)
    lnh = dd.pages[pi]["lines"][li]
    fields = [W("WHOLESALE HUB", "DOCUMENT IDENTIFIER"), W("Total VAT", "VAT"),
              W("Total", "TOTAL AMOUNT", n=len(V.find_all(dd, "Total", False)) - 1), V.new_row(lnh["text"], "LIST ITEM START")]
    if doc_type == "credit":
        fields += [W("Credit Note No", "INVOICE NO"), W("Original Invoice", "ORIGINAL INVOICE NO")]
    else:
        fields += [W("Invoice No", "INVOICE NO")]
    low = [n_.lower() for n_, _ in names]
    types_ = V.columns_from_list(names)
    for i_, (n_, hint) in enumerate(names):
        hh = got[i_]; r = V.new_row(hh["key"], types_[i_], list(hh["box"]), pi); r["case"] = low.count(n_.lower()) == 1
        fields.append(r)
    t_ = copy.deepcopy(DEFAULT_TEMPLATE)
    t_.update({"kind": "visual", "name": "Wholesale %s" % doc_type, "doc_type": doc_type, "prices_include_vat": False,
               "default_tax": "AUTO", "free_code": "C", "fields": fields})
    return t_
wi = os.path.join(samples, "wh_inv.pdf"); detailed_style(wi, "WH-1")
wc = os.path.join(samples, "wh_cn.pdf"); detailed_style(wc, "WCN-1", credit=True, orig="WH-1")
inv_t = wholesale_tpl(wi, "invoice"); cn_t = wholesale_tpl(wc, "credit")
s["templates"] = [inv_t, cn_t] + s["templates"]; s.save(); s.load()
detailed_style(os.path.join(s["input_dir"], "WH-1.pdf"), "WH-1"); eng.scan_once()
detailed_style(os.path.join(s["input_dir"], "WH-2 no amount column.pdf"), "WH-2", with_amount=False)
s["templates"] = [wholesale_tpl(os.path.join(s["input_dir"], "WH-2 no amount column.pdf"), "invoice", False)] + s["templates"]
s["templates"][0]["fields"][0]["key"] = "WHOLESALE HUB"
s.save(); s.load(); eng.scan_once()
detailed_style(os.path.join(s["input_dir"], "WCN-1.pdf"), "WCN-1", credit=True, orig="WH-1"); eng.scan_once()
detailed_style(os.path.join(s["input_dir"], "WH-3 amount only.pdf"), "WH-3")
s["templates"] = [wholesale_tpl(os.path.join(s["input_dir"], "WH-3 amount only.pdf"), "invoice",
                                col_list="No,TAX,ItemDescription,:Qty,:UnitPrice,:Tax,:DiscountRt,:DiscountAmt,Amount")] + s["templates"]
s.save(); s.load(); eng.scan_once()
wh3 = next((x for x in mock_vscu.STATE["sales"] if x["trdInvcNo"] == "WH-3"), None)
if wh3:
    print("   WH-3 (user's list) tot=%.2f vat=%.2f lines=%s" % (wh3["totAmt"], wh3["totTaxAmt"],
          [(i["itemNm"], i["taxTyCd"], i["qty"], i["totAmt"]) for i in wh3["itemList"]]))
wh = next((x for x in mock_vscu.STATE["sales"] if x["trdInvcNo"] == "WH-1"), None)
wh2 = next((x for x in mock_vscu.STATE["sales"] if x["trdInvcNo"] == "WH-2"), None)
wcn = next((x for x in mock_vscu.STATE["sales"] if x["trdInvcNo"] == "WCN-1"), None)
for nm, x in (("WH-1", wh), ("WH-2", wh2), ("WCN-1", wcn)):
    if x:
        print("   %s %s org=%s tot=%.2f vat=%.2f lines=%s" % (nm, x["rcptTyCd"], x["orgInvcNo"], x["totAmt"], x["totTaxAmt"],
              [(i["itemNm"], i["taxTyCd"], i["splyAmt"], i["dcAmt"], i["totAmt"]) for i in x["itemList"]]))

print("\n16) different templates by Input sub-folder (no identifier needed)")
fol = copy.deepcopy(s["templates"][0]); fol["name"] = "Wholesale (folder)"; fol["folder"] = "Wholesale"
fol["fields"] = [f_ for f_ in fol["fields"] if f_["type"] != "DOCUMENT IDENTIFIER"]  # only the folder chooses it
s["templates"] = s["templates"] + [fol]; s.save(); s.load(); s.make_folders()
detailed_style(os.path.join(s["input_dir"], "Wholesale", "WH-9.pdf"), "WH-9")
eng.scan_once()
fold_ok = os.path.exists(os.path.join(s["output_dir"], "Wholesale", "WH-9.pdf"))
print("   signed copy in Output\\Wholesale:", fold_ok)

print("\nRESULTS")
for r in eng.db.recent():
    print("  %-28s %-8s inv=%-5s %-6s total=%-9s %s" % (r["file_name"], r["status"], r["invc_no"], r["kind"], r["tot_amt"], (r["error"] or "")[:90]))
print("Output:", sorted(os.listdir(s["output_dir"])))
print("Error:", sorted(os.listdir(s["error_dir"])))
print("Archive:", len(os.listdir(s["archive_dir"])), "| Input left:", os.listdir(s["input_dir"]))
print("KRA sales:", [(x["invcNo"], x["trdInvcNo"], x["rcptTyCd"], x["orgInvcNo"], x["custTin"], x["custNm"], x["totAmt"], x["totTaxAmt"]) for x in mock_vscu.STATE["sales"]])
print("Items at KRA:", [(k, v["itemNm"], v["taxTyCd"]) for k, v in mock_vscu.STATE["items"].items()])
srv.shutdown()

# Self-check (the Windows build stops if any of these fail)
st = {r["file_name"]: (r["status"], r["invc_no"]) for r in eng.db.recent()}
want = {"QB Invoice 1045.pdf": ("signed", 101), "Sage SI-000233.pdf": ("signed", 102),
        "QB Credit CN-1045.pdf": ("signed", 103), "QB Invoice 1046.pdf": ("signed", 104),
        "QB Invoice 1046b.pdf": ("signed", 105), "QB Invoice 1046c.pdf": ("signed", 106),
        "QB Invoice 1047.pdf": ("signed", 110), "QB Invoice 1048.pdf": ("failed", None),
        "Lodge 95487.pdf": ("signed", 111), "Lodge CN.pdf": ("signed", 112), "Other seller.pdf": ("failed", None),
        "Duka milk only.pdf": ("signed", 113), "Duka mixed no rule.pdf": ("failed", None),
        "Duka mixed.pdf": ("signed", 114), "Duka all vat.pdf": ("signed", 115),
        "Duka mixed remembered.pdf": ("signed", 116), "Duka after expiry.pdf": ("signed", 117),
        "Duka eggs.pdf": ("signed", 118), "Duka USD.pdf": ("signed", 119),
        "Signed elsewhere.pdf": ("failed", None)}
want_extra = {"WH-1.pdf": "signed", "WH-2 no amount column.pdf": "signed", "WCN-1.pdf": "signed",
              "WH-3 amount only.pdf": "signed", "WH-9.pdf": "signed"}
bad = [(k, st.get(k), v) for k, v in want.items() if st.get(k) != v]
bad += [(k, st.get(k), v) for k, v in want_extra.items() if (st.get(k) or ("",))[0] != v]
sales = mock_vscu.STATE["sales"]
if len(sales) != 21: bad.append(("KRA sales count", len(sales), 21))
codes = lambda trd: [(i["itemNm"], i["taxTyCd"]) for x in sales if x["trdInvcNo"] == trd for i in x["itemList"]]
tax = lambda trd: next((x["totTaxAmt"] for x in sales if x["trdInvcNo"] == trd), None)
if codes("D-101") != [("Fresh milk 500ml", "C"), ("Long life milk 1L", "C")] or tax("D-101") != 0:
    bad.append(("milk only", codes("D-101"), tax("D-101")))
if codes("D-103") != [("Fresh milk 500ml", "C"), ("Bar soap 800g", "B")] or tax("D-103") != 32.0:
    bad.append(("mixed", codes("D-103"), tax("D-103")))
if codes("D-104") != [("Bar soap 800g", "B")] or tax("D-104") != 96.0:
    bad.append(("all vat", codes("D-104"), tax("D-104")))
if codes("D-105") != [("Long life milk 1L", "C"), ("Bar soap 800g", "B")]: bad.append(("remembered", codes("D-105"), None))
print("milk:", codes("D-101"), "| mixed:", codes("D-103"), tax("D-103"), "| all VAT:", codes("D-104"), tax("D-104"))
if lic_wait != ["Duka after expiry.pdf"]: bad.append(("licence wait", lic_wait, "stays in Input"))
if not wh or wh["totAmt"] != 5054.4 or wh["totTaxAmt"] != 614.4 or wh["itemList"][0]["dcAmt"] != 348.0:
    bad.append(("wholesale discounts", wh and (wh["totAmt"], wh["totTaxAmt"], wh["itemList"][0]["dcAmt"]), None))
if not wh2 or wh2["totAmt"] != 5054.4: bad.append(("no amount column", wh2 and wh2["totAmt"], 5054.4))
if not wh3 or wh3["totAmt"] != 5054.4 or [i["taxTyCd"] for i in wh3["itemList"]] != ["B", "C", "B"] or \
        any(i["qty"] != 1 for i in wh3["itemList"]):
    bad.append(("user column list", wh3 and wh3["totAmt"], 5054.4))
if not wcn or wcn["rcptTyCd"] != "R" or not wcn["orgInvcNo"]: bad.append(("credit template", wcn and wcn["rcptTyCd"], "R"))
if not fold_ok: bad.append(("folder routing", fold_ok, True))
if pos_ok != [True, True]: bad.append(("kra box position", pos_ok, None))
if len(rd) != 16 or rsum["count_cn"] != 2: bad.append(("report", len(rd), rsum["count_cn"]))
if len(rows) != 4 or errs or len(bad_errs) != 2: bad.append(("excel", len(rows), bad_errs))
if codes("D-201") != [("Eggs tray 30", "A"), ("Bar soap 800g", "B")]: bad.append(("eggs from list", codes("D-201"), None))
usd_sale = next((x for x in sales if x["trdInvcNo"] == "D-300"), None)
if not usd_sale or usd_sale["totAmt"] != 2600.0 or usd_sale["totTaxAmt"] != 358.62: bad.append(("usd", usd_sale and usd_sale["totAmt"], 2600))
print("eggs:", codes("D-201"), "| USD 20.00 ->", usd_sale and (usd_sale["totAmt"], usd_sale["totTaxAmt"]))
lodge_sale = next((x for x in sales if x["trdInvcNo"] == "95487"), None)
if not lodge_sale or lodge_sale["totAmt"] != 1174.09 or lodge_sale["totTaxAmt"] != 161.94 or \
        lodge_sale["custTin"] != "A002655384H" or lodge_sale["custNm"] != "DOREEN KOMBO":
    bad.append(("lodge sale", lodge_sale and (lodge_sale["totAmt"], lodge_sale["totTaxAmt"], lodge_sale["custNm"]), "1250/161.94"))
else:
    print("lodge lines:", [(i["itemNm"], i["taxTyCd"], i["totAmt"]) for i in lodge_sale["itemList"]])
cn = next((x for x in sales if x["trdInvcNo"] == "CN95487"), None)
if not cn or cn["rcptTyCd"] != "R" or cn["orgInvcNo"] != 111: bad.append(("lodge credit note", cn and cn["orgInvcNo"], 111))
if not any(x["rcptTyCd"] == "R" and x["orgInvcNo"] == 101 for x in sales): bad.append(("credit note link", None, 101))
if [f_ for f_ in os.listdir(s["input_dir"]) if f_.endswith(".pdf")]: bad.append(("input not empty", os.listdir(s["input_dir"]), []))
if len([f_ for f_ in os.listdir(s["output_dir"]) if f_.endswith(".pdf")]) != 21:
    bad.append(("output count", len(os.listdir(s["output_dir"])), 21))
if bad:
    print("\nE2E FAILED:", bad); sys.exit(1)
print("\nE2E PASSED")
