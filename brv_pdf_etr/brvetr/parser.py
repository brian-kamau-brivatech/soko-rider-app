"""Reads an invoice PDF with a client template: header fields and item lines."""
import re

import pdfplumber

from . import visual

FLAGS = re.I | re.M


def num(s):
    if s is None:
        return None
    s = str(s).replace(",", "").replace(" ", "").strip()
    neg = s.startswith("(") and s.endswith(")")
    s = s.strip("()")
    try:
        v = float(s)
    except ValueError:
        return None
    return -v if neg else v


def pdf_text(path, info=None):
    """All text of the PDF, page by page (layout kept so columns stay on one line).
    Pages without a text layer are read with OCR (add-on) when it is installed."""
    pages, need = [], []
    with pdfplumber.open(path) as pdf:
        for i, page in enumerate(pdf.pages):
            t = visual.visible(page).extract_text(x_tolerance=1.5, y_tolerance=3) or ""
            if len(page.chars) < 5:
                need.append(i)
            pages.append(t)
    if need:
        from . import ocr
        if ocr.available():
            got = ocr.ocr_pdf(path, need)
            for i, words in got.items():
                pages[i] = "\n".join(l["text"] for l in visual.Doc._lines(words))
            if info is not None:
                info["ocr"] = True
    return pages


def _first(pattern, text, next_line_if_empty=False):
    if not pattern:
        return ""
    try:
        m = re.search(pattern, text, FLAGS)
    except re.error as e:
        raise ValueError("Bad pattern %r: %s" % (pattern, e))
    if not m:
        return ""
    val = (m.group(1) if m.groups() else m.group(0)) or ""
    val = val.strip()
    if not val and next_line_if_empty:
        rest = text[m.end():].splitlines()
        for ln in rest:
            if ln.strip():
                return ln.strip()
    return val


def pick_template(templates, text, doc=None):
    """First template whose 'match' text is found; else the first with an empty match."""
    fallback = None
    for t in templates:
        if t.get("kind") == "visual":
            ok = visual.matches(t, doc) if doc is not None else None
            if ok:
                return t
            if ok is None:
                fallback = fallback or t
            continue
        if (t.get("doc_type") or "auto").lower() == "invoice" and re.search(r"credit\s*note", text, re.I):
            continue  # an Invoice template never signs a credit note
        m = (t.get("match") or "").strip()
        if not m:
            fallback = fallback or t
            continue
        try:
            if re.search(m, text, FLAGS):
                return t
        except re.error:
            continue
    return fallback


def parse_lines(tpl, text):
    lines_out, notes = [], []
    try:
        line_re = re.compile(tpl["line"], re.I)
    except re.error as e:
        raise ValueError("Bad item line pattern: %s" % e)
    start = tpl.get("lines_start") or ""
    stop = tpl.get("lines_stop") or ""
    started = not start
    for raw in text.splitlines():
        ln = raw.strip()
        if not ln:
            continue
        if not started:
            if re.search(start, ln, re.I):
                started = True
            continue
        m = line_re.search(ln)
        if m:
            g = m.groupdict()
            qty, price, amount = num(g.get("qty")), num(g.get("price")), num(g.get("amount"))
            if amount is None and qty is not None and price is not None:
                amount = qty * price
            if qty is None and amount is not None and price:
                qty = amount / price
            if qty is None or amount is None:
                continue
            lines_out.append({
                "desc": re.sub(r"\s+", " ", (g.get("desc") or "").strip()),
                "code": (g.get("code") or "").strip(),
                "qty": qty, "price": price if price is not None else (amount / qty if qty else 0),
                "amount": amount, "tax_raw": (g.get("tax") or "").strip(),
            })
            continue
        if stop and re.search(r"^(?:%s)\b" % stop, ln, re.I) and lines_out:
            break
        # A description that wrapped onto the next line: add it to the item above.
        if lines_out and not re.search(r"\d+\.\d{2}|\d\s*$", ln) and len(ln) < 80:
            lines_out[-1]["desc"] = (lines_out[-1]["desc"] + " " + ln).strip()[:200]
        elif re.search(r"\d", ln):
            notes.append("Not read as an item: %s" % ln)
    return lines_out, notes


def line_tax(tpl, ln):
    return ln.get("tax") or tax_code(tpl, ln.get("tax_raw"))


def line_incl(tpl, ln):
    """True when the line amount already includes VAT."""
    return ln["incl"] if "incl" in ln else bool(tpl.get("prices_include_vat", True))


def tax_code(tpl, raw):
    if not raw:
        return tpl.get("default_tax") or "B"
    mp = {str(k).upper(): v for k, v in (tpl.get("tax_map") or {}).items()}
    key = raw.upper().replace(" ", "")
    if key in mp:
        return mp[key]
    if key.rstrip("%") in mp:
        return mp[key.rstrip("%")]
    if key in ("A", "B", "C", "D", "E"):
        return key
    return tpl.get("default_tax") or "B"


def parse(path, templates, own_tin="", force=None):
    """force = the template of the Input sub-folder the PDF was put in (no matching needed)."""
    info = {}
    pages = pdf_text(path, info)
    text = "\n".join(pages)
    if not text.strip():
        from . import ocr
        raise ValueError("No text found in the PDF: the text is a picture (scanned, or printed as shapes). " +
                         ("Install the BRV OCR add-on to read such PDFs, or p" if not ocr.available() else "P") +
                         "rint the invoice to PDF so that the text is kept.")
    doc = visual.Doc(path) if any(t.get("kind") == "visual" for t in ([force] if force else templates)) else None
    tpl = force or pick_template(templates, text, doc)
    if not tpl:
        raise ValueError("No template fits this PDF (none of the templates' DOCUMENT IDENTIFIER texts were found). "
                         "Add a template for this layout, or put the PDF in the Input sub-folder of its template.")
    if force and (force.get("doc_type") or "auto").lower() == "invoice" and re.search(r"credit\s*note", text, re.I):
        raise ValueError("This PDF says 'credit note' but it was put in the folder of an Invoice template.")
    if tpl.get("kind") == "visual":
        got = visual.read(doc, tpl, own_tin)
        got.update({"template": tpl, "text": text, "pages": len(pages), "ocr": bool(info.get("ocr") or doc.ocr)})
        return got
    pins = []
    if tpl.get("customer_pin"):
        try:
            pins = [m.group(1) if m.groups() else m.group(0) for m in re.finditer(tpl["customer_pin"], text, FLAGS)]
        except re.error as e:
            raise ValueError("Bad customer PIN pattern: %s" % e)
    own = (own_tin or "").upper()
    pins = [p.upper() for p in pins if p and p.upper() != own]
    lines, notes = parse_lines(tpl, text)
    doc_type = (tpl.get("doc_type") or "auto").lower()
    credit = doc_type == "credit" or (doc_type != "invoice" and bool(
        tpl.get("credit_note") and re.search(tpl["credit_note"], text, FLAGS)))
    total_raw = _first(tpl.get("total"), text)
    # "Total" may appear several times (sub total, VAT total...): the grand total is the last one.
    if tpl.get("total"):
        try:
            all_totals = [num(m.group(1) if m.groups() else m.group(0)) for m in re.finditer(tpl["total"], text, FLAGS)]
            all_totals = [t for t in all_totals if t is not None]
            if all_totals:
                total_raw = str(max(all_totals, key=abs))
        except re.error:
            pass
    return {
        "template": tpl,
        "ocr": bool(info.get("ocr")),
        "text": text,
        "pages": len(pages),
        "invoice_no": (_first(tpl.get("credit_note_no"), text) if credit else "") or _first(tpl.get("invoice_no"), text),
        "date": _first(tpl.get("date"), text),
        "customer_name": _first(tpl.get("customer_name"), text, next_line_if_empty=True)[:60],
        "customer_pin": pins[0] if pins else "",
        "total": num(total_raw),
        "credit_note": credit,
        "original_invoice": _first(tpl.get("original_invoice"), text) if credit else "",
        "lines": lines,
        "notes": notes,
    }
