"""Templates made by clicking on a sample PDF (the designer).

Each row of a template says: find this KEY text on the invoice, it is of this TYPE, and the value is
to the RIGHT of it, BELOW it, or inside a fixed BOX. Positions are kept so the nearest match wins when
the same text appears more than once. Item lines are the rows between LIST ITEM START and LIST ITEM END,
cut into columns by the column headings. Invoices without readable item lines (hotel folios...) are
signed from their totals: NETT + VAT, non-taxable, service charge, catering levy...
"""
import re

import pdfplumber

from . import kra

# type -> (label, kind). kind: key = only the key is needed, value = read a value, amount = read a number,
# col = an item column heading, list = start/end of the item list.
TYPES = [
    ("DOCUMENT IDENTIFIER", "key", "Text that is on every invoice of this client (picks this template)"),
    ("INVOICE NO", "value", "Invoice number"),
    ("DATE", "value", "Invoice date"),
    ("CUSTOMER NAME", "value", "Customer name"),
    ("CUSTOMER TIN", "value", "Customer KRA PIN"),
    ("DOCUMENT TIN", "value", "Seller's own KRA PIN (checked against Settings)"),
    ("CREDIT NOTE IDENTIFIER", "key", "Text found only on credit notes"),
    ("CREDIT NOTE NO", "value", "Credit note number"),
    ("ORIGINAL INVOICE NO", "value", "On credit notes: the invoice being credited"),
    ("CURRENCY", "value", "Currency printed on the invoice (KSH, USD...)"),
    ("EXCHANGE RATE", "amount", "Exchange rate printed on the invoice (USD -> KES)"),
    ("LIST ITEM START", "list", "Item lines start after this text (usually the column headings)"),
    ("LIST ITEM END", "list", "Item lines stop before this text"),
    ("COLUMN DESCRIPTION", "col", "Item column: description"),
    ("COLUMN CODE", "col", "Item column: item code (matched with the Items list)"),
    ("COLUMN QTY", "col", "Item column: quantity"),
    ("COLUMN PRICE", "col", "Item column: unit price"),
    ("COLUMN AMOUNT", "col", "Item column: line amount"),
    ("COLUMN DEBIT", "col", "Item column: debit (charges)"),
    ("COLUMN CREDIT", "col", "Item column: credit (payments, discounts)"),
    ("COLUMN TAX", "col", "Item column: VAT code or rate (B, 16%, E...)"),
    ("COLUMN VAT AMOUNT", "col", "Item column: VAT amount of the line"),
    ("COLUMN DISCOUNT RATE", "col", "Item column: discount %"),
    ("COLUMN DISCOUNT AMOUNT", "col", "Item column: discount amount"),
    ("COLUMN NO", "col", "Item column: line number (not used)"),
    ("COLUMN IGNORE", "col", "Item column to ignore (date, code...)"),
    ("TOTAL AMOUNT", "amount", "Invoice total (everything must add up to it)"),
    ("NET TAXABLE", "amount", "Taxable amount before VAT"),
    ("VAT", "amount", "VAT amount"),
    ("NON TAXABLE", "amount", "Non-taxable amount (choose its KRA code)"),
    ("ZERO RATED", "amount", "Zero-rated amount (0% VAT, KRA code C)"),
    ("EXEMPT", "amount", "Exempt amount (no VAT, KRA code A)"),
    ("SERVICE CHARGE", "amount", "Service charge (not sent to KRA unless 'TO KRA' is ticked)"),
    ("CATERING LEVY", "amount", "Catering / tourism levy (not sent to KRA unless 'TO KRA' is ticked)"),
    ("OTHER CHARGE", "amount", "Any other charge added to the total"),
]
KIND = {t: k for t, k, _ in TYPES}
HELP = {t: h for t, _, h in TYPES}
TYPE_NAMES = [t for t, _, _ in TYPES]
NUMERIC_COLS = ("COLUMN QTY", "COLUMN PRICE", "COLUMN AMOUNT", "COLUMN DEBIT", "COLUMN CREDIT", "COLUMN VAT AMOUNT",
                "COLUMN DISCOUNT RATE", "COLUMN DISCOUNT AMOUNT", "COLUMN NO")
# Column heading -> type, for the quick "Item columns" set-up (":" before a name = column not used).
COLUMN_WORDS = [
    (("no", "#", "sn", "s/n", "line", "ln"), "COLUMN NO"),
    (("discountrt", "discount rate", "disc rate", "disc%", "discount%", "disc %", "dis%", "dcrt", "discount rt",
      "disc rt", "discount %", "disc. %", "disc.%"), "COLUMN DISCOUNT RATE"),
    (("discountamt", "discount amount", "disc amt", "discount amt", "discount", "disc", "dcamt", "disc. amt"),
     "COLUMN DISCOUNT AMOUNT"),
    (("itemdescription", "description", "item description", "desc", "particulars", "details", "item name", "item",
      "product", "goods", "billing", "charges", "service", "services", "narration"), "COLUMN DESCRIPTION"),
    (("qty", "quantity", "qnty", "units"), "COLUMN QTY"),
    (("unitprice", "unit price", "price", "rate", "unit cost", "u/price"), "COLUMN PRICE"),
    (("amount", "total", "line total", "value", "net amount", "sum"), "COLUMN AMOUNT"),
    (("code", "item code", "sku", "barcode"), "COLUMN CODE"),
    (("debit",), "COLUMN DEBIT"), (("credit",), "COLUMN CREDIT"),
]


def column_type(name, tax_taken=False):
    """Type for one heading of the item table. The first 'TAX'/'VAT' = VAT code column, a second one = VAT amount."""
    n = re.sub(r"\s+", " ", name.strip().lower())
    if n in ("tax", "vat", "tax code", "vat code", "tax type", "taxtype", "tax cat", "vat cat", "%tax", "tax%", "% tax",
             "%vat", "vat%", "% vat", "tax rate", "vat rate", "tax %", "vat %"):
        return "COLUMN VAT AMOUNT" if tax_taken and n in ("tax", "vat") else "COLUMN TAX"
    if n in ("tax amount", "vat amount", "taxamt", "vatamt", "tax amt", "vat amt"):
        return "COLUMN VAT AMOUNT"
    for words, typ in COLUMN_WORDS:
        if n in words:
            return typ
    for words, typ in COLUMN_WORDS:
        if any(w in n for w in words if len(w) > 3):
            return typ
    return "COLUMN IGNORE"


def parse_column_list(text):
    """'/No,TAX,ItemDescription,:Qty,...,Amount' -> [(name, not_used)].
    ':' before a heading = the column is on the invoice but NOT used (it only marks where columns are)."""
    out = []
    for part in text.replace(";", ",").split(","):
        p = part.strip().lstrip("/").strip()
        unused = p.startswith(":")
        p = p.lstrip(":").strip()
        if p:
            out.append((p, unused))
    return out


def columns_from_list(names):
    """[(name, not_used)] -> [type] for each heading."""
    types, tax_taken = [], False
    for name, unused in names:
        if unused:
            types.append("COLUMN IGNORE")
            continue
        t = column_type(name, tax_taken)
        tax_taken = tax_taken or t == "COLUMN TAX"
        types.append(t)
    return types


def name_variants(name):
    """'ItemDescription' -> ['ItemDescription', 'Item Description']; 'DiscountRt' -> [..., 'Discount Rt']."""
    out = [name]
    split = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name)
    if split != name:
        out.append(split)
    return out


HEADING_HINTS = {"qty", "quantity", "price", "rate", "amount", "total", "description", "desc", "item", "items", "tax", "vat",
                 "%tax", "%vat", "debit", "credit", "code", "particulars", "details", "unit", "no", "disc", "discount",
                 "billing", "product", "value", "net", "gross", "curr", "uom", "sku", "date"}


HEADING_PAIRS = {"item code", "item description", "item name", "item no", "unit price", "unit cost", "fc amount",
                 "discount rt", "discount amt", "discount amount", "discount rate", "disc amt", "disc rate", "line total",
                 "net amount", "tax code", "vat code", "tax amount", "vat amount", "tax rate", "vat rate", "order ref",
                 "line no", "sr no", "s/n no", "product code", "product name", "total amount", "u/price"}


def guess_headings(doc):
    """Autofill for 'Item columns...': the headings of the item table, as 'Item Code,Qty,Description,...'.
    Columns the app would not use (code, number, date, unknown) get ':' in front."""
    best = None
    for pi, pg in enumerate(doc.pages):
        for li, ln in enumerate(pg["lines"]):
            words = [re.sub(r"[^a-z%]", "", w["text"].lower()) for w in ln["words"]]
            score = sum(1 for w in words if w in HEADING_HINTS)
            if score < 3 or len(ln["words"]) > 16:
                continue
            nxt = pg["lines"][li + 1:li + 4]
            if not any(re.search(r"\d+[.,]\d{2}", n["text"]) for n in nxt):
                continue  # a heading line has number lines under it
            if best is None or score > best[0]:
                best = (score, pi, li)
    if not best:
        return ""
    ln = doc.pages[best[1]]["lines"][best[2]]
    heads = []  # [[words], x1 of last word, width of a letter]
    for w in ln["words"]:
        cw = (w["x1"] - w["x0"]) / max(1, len(w["text"]))
        low = re.sub(r"[^a-z%/ ]", "", w["text"].lower())
        if heads:
            prev = heads[-1]
            gap = w["x0"] - prev[1]
            pair = (re.sub(r"[^a-z%/]", "", prev[0][-1].lower()) + " " + low).strip()
            prev_hint = re.sub(r"[^a-z%]", "", prev[0][-1].lower()) in HEADING_HINTS
            if pair in HEADING_PAIRS or (gap < 1.6 * max(cw, prev[2]) and low not in HEADING_HINTS and not prev_hint):
                prev[0].append(w["text"])
                prev[1] = w["x1"]
                continue
        heads.append([[w["text"]], w["x1"], cw])
    out, taken = [], set()
    for words, _x1, _cw in heads:
        h = " ".join(words)
        t = column_type(h, "COLUMN TAX" in taken)
        if re.match(r"^(fc|foreign|usd|eur|gbp)\b", h.strip().lower()):
            t = "COLUMN IGNORE"  # foreign-currency amount: the KES column is used
        unused = t in ("COLUMN IGNORE", "COLUMN NO", "COLUMN CODE") or t in taken
        taken.add(t)
        out.append((":" if unused else "") + h)
    return ",".join(out)


def find_header(doc, names):
    """The text line that holds most of the headings, and each heading's place on it."""
    best = None
    for pi, pg in enumerate(doc.pages):
        for li, ln in enumerate(pg["lines"]):
            got = {}
            used = set()
            for idx, (name, _h) in enumerate(names):
                for variant in name_variants(name):
                    for exact in (True, False):
                        for hit in [h for h in find_all(doc, variant, not exact) if h["page"] == pi and h["line"] == li]:
                            span = (hit["first"], hit["last"])
                            if any(not (span[1] < u[0] or span[0] > u[1]) for u in used):
                                continue
                            got[idx] = dict(hit, key=variant, exact=exact)
                            used.add(span)
                            break
                        if idx in got:
                            break
                    if idx in got:
                        break
            if got and (best is None or len(got) > len(best[2])):
                best = (pi, li, got)
    return best
VALUE_FROM = ["RIGHT", "RIGHT 2", "RIGHT 3", "BELOW", "BOX"]
# KRA tax code and item name used when an amount becomes a line of the sale.
CHARGE_DEFAULTS = {
    "NET TAXABLE": ("AUTO", "Taxable sales"),
    "NON TAXABLE": ("A", "Non-taxable sales"),
    "ZERO RATED": ("C", "Zero-rated sales"),
    "EXEMPT": ("A", "Exempt sales"),
    "SERVICE CHARGE": ("B", "Service charge"),
    "CATERING LEVY": ("D", "Catering levy"),
    "OTHER CHARGE": ("B", "Other charges"),
    "TOTAL AMOUNT": ("AUTO", "Sales as per invoice"),
}
# Amounts that are part of the invoice total but are NOT sent to KRA unless ticked (eTIMS gets the
# effective total; levies collected for others stay out).
NOT_SENT = ("SERVICE CHARGE", "CATERING LEVY")
PIN_RE = re.compile(r"\b([AP]\d{9}[A-Z])\b", re.I)
NUM_RE = re.compile(r"\(?-?[\d,]*\d(?:\.\d+)?\)?-?")


def norm_currency(text):
    t = (text or "").upper().replace(" ", "")
    if not t:
        return ""
    for code, signs in (("USD", ("USD", "US$", "$", "DOLLAR")), ("EUR", ("EUR", "€", "EURO")),
                        ("GBP", ("GBP", "£", "POUND")), ("KES", ("KES", "KSH", "KSHS", "SHILLING")),
                        ("UGX", ("UGX",)), ("TZS", ("TZS",))):
        if any(sg in t for sg in signs):
            return code
    m = re.search(r"[A-Z]{3}", t)
    return m.group(0) if m else ""


def new_row(key="", typ="INVOICE NO", pos=None, page=0):
    return {"key": key, "type": typ, "sep": ":", "from": "RIGHT", "case": True, "pos": pos, "page": page,
            "send": typ not in NOT_SENT,
            "tax": CHARGE_DEFAULTS.get(typ, ("", ""))[0], "item": CHARGE_DEFAULTS.get(typ, ("", ""))[1]}


def num(s):
    if s is None:
        return None
    m = NUM_RE.search(str(s).replace(" ", ""))
    if not m:
        return None
    t = m.group(0)
    neg = (t.startswith("(") and t.endswith(")")) or t.startswith("-") or t.endswith("-")
    t = t.strip("()-").replace(",", "")
    try:
        v = float(t)
    except ValueError:
        return None
    return -v if neg else v


# ---------------------------------------------------------------------------- the PDF as words and lines
class Doc:
    """Words of every page (PDF points, origin top-left) grouped into text lines."""

    def __init__(self, path, use_ocr=True):
        self.path = path
        self.pages = []  # [{"w":, "h":, "lines": [{"top","bottom","words":[...], "text", "spans"}]}]
        self.ocr = False
        need = []
        with pdfplumber.open(path) as pdf:
            for i, pg in enumerate(pdf.pages):
                words = visible(pg).extract_words(x_tolerance=1.5, y_tolerance=3, keep_blank_chars=False)
                if len(pg.chars) < 5:
                    need.append(i)  # no text layer: the text is drawn as shapes or scanned
                self.pages.append({"w": float(pg.width), "h": float(pg.height), "lines": self._lines(words)})
        if need and use_ocr:
            from . import ocr
            try:
                got = ocr.ocr_pdf(path, need)
            except RuntimeError as e:
                raise ValueError(str(e))
            for i, words in got.items():
                self.pages[i]["lines"] = self._lines(words)
            self.ocr = True

    @staticmethod
    def _lines(words):
        words = sorted(words, key=lambda w: (round(w["top"]), w["x0"]))
        lines = []
        for w in words:
            mid = (w["top"] + w["bottom"]) / 2
            for ln in lines[-4:]:
                if ln["top"] - 1 <= mid <= ln["bottom"] + 1:
                    ln["words"].append(w)
                    ln["top"], ln["bottom"] = min(ln["top"], w["top"]), max(ln["bottom"], w["bottom"])
                    break
            else:
                lines.append({"top": w["top"], "bottom": w["bottom"], "words": [w]})
        lines.sort(key=lambda l: l["top"])
        for ln in lines:
            ln["words"].sort(key=lambda w: w["x0"])
            text, spans = "", []
            for w in ln["words"]:
                if text:
                    text += " "
                spans.append((len(text), len(text) + len(w["text"])))
                text += w["text"]
            ln["text"], ln["spans"] = text, spans
        return lines

    @property
    def text(self):
        return "\n".join("\n".join(l["text"] for l in p["lines"]) for p in self.pages)

    def words_in(self, page, box):
        x0, y0, x1, y1 = box
        out = []
        for ln in self.pages[page]["lines"]:
            ws = [w for w in ln["words"] if x0 <= (w["x0"] + w["x1"]) / 2 <= x1 and y0 <= (w["top"] + w["bottom"]) / 2 <= y1]
            if ws:
                out.append(ws)
        return out


def _white(c):
    col = c.get("non_stroking_color")
    if col is None:
        return False
    if isinstance(col, (int, float)):
        col = (col,)
    col = tuple(col)
    return col in ((1,), (1.0,), (1, 1, 1), (1.0, 1.0, 1.0), (0, 0, 0, 0), (0.0, 0.0, 0.0, 0.0))


def visible(page):
    """The page without white text on a white background (invisible) - some programs hide text like
    'Error' in white. White text on a dark bar or picture is kept (it can be seen)."""
    bgs = []
    try:
        for r in list(page.rects) + list(getattr(page, "curves", [])):
            if r.get("fill") and not _white(r):
                bgs.append((r["x0"], r["top"], r["x1"], r["bottom"]))
        for im in page.images:
            bgs.append((im["x0"], im["top"], im["x1"], im["bottom"]))
    except Exception:
        pass

    def on_dark(c):
        cx, cy = (c["x0"] + c["x1"]) / 2, (c["top"] + c["bottom"]) / 2
        return any(x0 - 1 <= cx <= x1 + 1 and y0 - 1 <= cy <= y1 + 1 for x0, y0, x1, y1 in bgs)
    try:
        page = page.dedupe_chars(tolerance=1)  # fake bold: the same letter printed 2-4 times on top of itself
    except Exception:
        pass
    # spaces printed on top of letters/digits (some till programs) would cut '16' into '1 6'
    filled = {}
    for c in page.chars:
        if c["text"].strip():
            filled.setdefault(round(c["top"]), []).append((c["x0"], c["x1"]))

    def space_on_char(c):
        if c["text"].strip():
            return False
        cx = (c["x0"] + c["x1"]) / 2
        for k in (round(c["top"]) - 1, round(c["top"]), round(c["top"]) + 1):
            if any(a - 0.3 <= cx <= b + 0.3 for a, b in filled.get(k, ())):
                return True
        return False
    return page.filter(lambda o: not (o.get("object_type") == "char" and (
        (_white(o) and not on_dark(o)) or space_on_char(o))))


def _norm(s):
    return re.sub(r"\s+", " ", (s or "").strip())


def find_all(doc, key, case=True):
    """Every place the key text appears: (page, line index, first word, last word, char end in last word)."""
    key = _norm(key)
    if not key:
        return []
    flags = re.I if case else 0
    body = re.escape(key).replace(r"\ ", r"\s*")
    pat = re.compile(("\\b" if key[0].isalnum() else "") + body + ("\\b" if key[-1].isalnum() else ""), flags)
    hits = []
    for pi, pg in enumerate(doc.pages):
        for li, ln in enumerate(pg["lines"]):
            for m in pat.finditer(ln["text"]):
                a, b = m.start(), m.end()
                wi = [i for i, (s, e) in enumerate(ln["spans"]) if s < b and e > a]
                if not wi:
                    continue
                first, last = wi[0], wi[-1]
                ws = ln["words"][first:last + 1]
                hits.append({"page": pi, "line": li, "first": first, "last": last,
                             "cut": b - ln["spans"][last][0],  # characters of the last word that are key
                             "box": (ws[0]["x0"], ln["top"], ws[-1]["x1"], ln["bottom"])})
    return hits


def find(doc, row):
    hits = find_all(doc, row.get("key"), row.get("case", True))
    if not hits:
        return None
    pos = row.get("pos")
    if not pos:
        return hits[0]
    pg = row.get("page", 0)

    def dist(h):
        x0, y0 = h["box"][0], h["box"][1]
        return (0 if h["page"] == pg else 100000) + abs(x0 - pos[0]) + abs(y0 - pos[1]) * 1.5
    return min(hits, key=dist)


def _run(tokens):
    """First token plus the tokens that follow it closely (one value, not the next column)."""
    if not tokens:
        return [], None
    out = [tokens[0]]
    for t in tokens[1:]:
        prev = out[-1]
        cw = max(2.0, (prev["x1"] - prev["x0"]) / max(1, len(prev["text"])))
        if t["x0"] - prev["x1"] > max(5.0, 2.2 * cw):
            break
        out.append(t)
    return out, (out[0]["x0"], min(t["top"] for t in out), out[-1]["x1"], max(t["bottom"] for t in out))


def _strip_sep(tokens, sep):
    seps = [s for s in (sep or "") if not s.isspace()] + [":"]
    while tokens:
        t = tokens[0]
        txt = t["text"]
        stripped = txt.lstrip("".join(seps)).lstrip()
        if stripped == txt:
            break
        if stripped:
            tokens[0] = dict(t, text=stripped)
            break
        tokens = tokens[1:]
    return tokens


def read_value(doc, row, hit=None):
    """(text, value box, key box, page) for one template row."""
    kind = KIND.get(row.get("type"), "value")
    if row.get("from") == "BOX" and row.get("pos") and kind in ("value", "amount"):
        # A fixed area of the page (for values printed without a label, e.g. the customer's name).
        p = min(row.get("page", 0), len(doc.pages) - 1)
        box = tuple(row["pos"])
        text = " ".join(" ".join(w["text"] for w in ln) for ln in doc.words_in(p, box))
        return _norm(text), box, None, p
    h = hit or find(doc, row)
    if not h:
        return "", None, None, None
    if kind in ("key", "list", "col"):
        return _norm(row.get("key")), None, h["box"], h["page"]
    pg = doc.pages[h["page"]]
    ln = pg["lines"][h["line"]]
    if row.get("from") == "BELOW":
        kx0, _, kx1, kbot = h["box"]
        for nxt in pg["lines"][h["line"] + 1:]:
            if nxt["top"] - kbot > 3 * max(6.0, ln["bottom"] - ln["top"]):
                break
            toks = [w for w in nxt["words"] if w["x1"] >= kx0 - 4 and w["x0"] <= kx1 + 40]
            if toks:
                toks = [w for w in nxt["words"] if w["x0"] >= toks[0]["x0"]]
                run, box = _run(toks)
                return _norm(" ".join(t["text"] for t in run)), box, h["box"], h["page"]
        return "", None, h["box"], h["page"]
    # RIGHT: the rest of the last key word, then the words after it on the same line.
    words = ln["words"]
    last = words[h["last"]]
    rest = last["text"][h["cut"]:]
    toks = []
    if rest:
        cw = (last["x1"] - last["x0"]) / max(1, len(last["text"]))
        toks.append(dict(last, text=rest, x0=last["x0"] + cw * h["cut"]))
    toks += words[h["last"] + 1:]
    toks = _strip_sep(toks, row.get("sep"))
    if toks and toks[0]["x0"] - h["box"][2] > 120:
        far, _b = _run(toks)
        if any(t["text"].endswith(":") or t["text"] == ":" for t in far):
            toks = []  # the next words far away are another label (e.g. 'Voucher No. :'): this value is empty
    nth = {"RIGHT 2": 2, "RIGHT 3": 3}.get(row.get("from") or "RIGHT", 1)
    run, box = _run(toks)
    while nth > 1 and run:  # skip to the 2nd / 3rd value on the line (e.g. VAT after Nett)
        toks = toks[len(run) + toks.index(run[0]):] if run[0] in toks else toks[len(run):]
        toks = _strip_sep(toks, row.get("sep"))
        run, box = _run(toks)
        nth -= 1
    return _norm(" ".join(t["text"] for t in run)), box, h["box"], h["page"]


# ---------------------------------------------------------------------------- item list
def _columns(doc, rows, start_hit):
    cols = []
    for r in rows:
        if KIND.get(r["type"]) != "col":
            continue
        hits = find_all(doc, r["key"], r.get("case", True))
        if start_hit:  # the heading nearest the start of the list (then nearest to where it was marked)
            px = (r.get("pos") or [None])[0]
            hits.sort(key=lambda h: (h["page"] != start_hit["page"], round(abs(h["box"][1] - start_hit["box"][1]) / 4),
                                     abs(h["box"][0] - px) if px is not None else 0))
        elif r.get("pos"):
            hits.sort(key=lambda h: abs(h["box"][0] - r["pos"][0]) + abs(h["box"][1] - r["pos"][1]))
        if hits:
            cols.append({"type": r["type"], "x0": hits[0]["box"][0], "x1": hits[0]["box"][2], "row": r})
    cols.sort(key=lambda c: c["x0"])
    return cols


def _assign(word, cols):
    is_num = num(word["text"]) is not None and re.fullmatch(r"[\d,().\-]+", word["text"]) is not None
    if is_num:
        # number columns that are not used still take their numbers (so they do not end up in another column)
        nums = [c for c in cols if c["type"] in NUMERIC_COLS or c["type"] == "COLUMN IGNORE"]
        if nums:
            best = min(nums, key=lambda c: abs(word["x1"] - c["x1"]))
            if abs(word["x1"] - best["x1"]) <= 45 or (best["x0"] - 10 <= word["x0"] <= best["x1"] + 10):
                return best
    left = [c for c in cols if c["x0"] <= word["x0"] + 3]
    if left:
        c = left[-1]
        if c["type"] in NUMERIC_COLS and not is_num:
            return None
        return c
    # left of the first heading (headings are often centred over their column): first column
    return cols[0] if cols and not is_num else None


def item_lines(doc, rows, notes):
    start_r = next((r for r in rows if r["type"] == "LIST ITEM START" and r.get("key")), None)
    end_r = next((r for r in rows if r["type"] == "LIST ITEM END" and r.get("key")), None)
    if not start_r:
        return [], []
    sh = find(doc, start_r)
    if not sh:
        notes.append("The list start text '%s' was not found." % start_r["key"])
        return [], []
    cols = _columns(doc, rows, sh)
    if not cols:
        return [], []
    eh = None
    end_words = re.compile(r"^\s*(sub\s*-?\s*total|total|grand\s*total|vat\b|amount\s*due|invoice\s*total|net\b|gross\b)",
                           re.I)
    if end_r:
        cand = [h for h in find_all(doc, end_r["key"], end_r.get("case", True))
                if (h["page"], h["line"]) > (sh["page"], sh["line"])]
        eh = cand[0] if cand else None
        if not eh:
            notes.append("The list end text '%s' was not found after the start." % end_r["key"])
    heading_words = {_norm(c["row"]["key"]).lower() for c in cols} | {_norm(start_r["key"]).lower()}
    out, boxes = [], []
    for pi in range(sh["page"], len(doc.pages)):
        pg = doc.pages[pi]
        for li, ln in enumerate(pg["lines"]):
            if (pi, li) <= (sh["page"], sh["line"]):
                continue
            if eh and (pi, li) >= (eh["page"], eh["line"]):
                return out, boxes
            if re.fullmatch(r"[\s\-_=.*]+", ln["text"]):
                continue  # ---------- separator lines
            if not end_r and end_words.search(ln["text"]):
                return out, boxes  # no LIST ITEM END row: stop at the first Total / Sub total line
            if _norm(ln["text"]).lower() in heading_words or (
                    pi != sh["page"] and _norm(start_r["key"]).lower() in ln["text"].lower()):
                continue  # headings repeated on the next page
            cells = {}
            for w in ln["words"]:
                c = _assign(w, cols)
                if c:
                    cells.setdefault(c["type"], []).append(w["text"])
            get = lambda t: " ".join(cells.get(t, []))
            amount = num(get("COLUMN AMOUNT")) if "COLUMN AMOUNT" in cells else None
            debit, credit = num(get("COLUMN DEBIT")), num(get("COLUMN CREDIT"))
            qty, price = num(get("COLUMN QTY")), num(get("COLUMN PRICE"))
            disc_amt, disc_rt = num(get("COLUMN DISCOUNT AMOUNT")), num(get("COLUMN DISCOUNT RATE"))
            vat_amt = num(get("COLUMN VAT AMOUNT")) if "COLUMN VAT AMOUNT" in cells else None
            if amount is None and (debit is not None or credit is not None):
                amount = (debit or 0) - (credit or 0)
            discount = 0.0
            if qty is not None and price is not None:
                gross = qty * price
                if disc_amt:
                    discount = abs(disc_amt)
                elif disc_rt:
                    discount = gross * abs(disc_rt) / 100
                if amount is None:  # no Amount column (or not used): qty x price - discount
                    amount = round(gross - discount, 2)
                elif discount == 0 and gross - amount > 0.01:
                    discount = round(gross - amount, 2)  # amount printed after a discount
            desc = re.sub(r"^\d{1,3}[.)]\s*", "", _norm(get("COLUMN DESCRIPTION")))  # '1. UCR CHARGES' -> 'UCR CHARGES'
            desc = re.sub(r"\s*\*+$", "", desc)
            box = (min(w["x0"] for w in ln["words"]), ln["top"], max(w["x1"] for w in ln["words"]), ln["bottom"])
            if amount is None:
                if out and desc and pi == out[-1]["page"]:
                    out[-1]["desc"] = (out[-1]["desc"] + " " + desc)[:200]  # description wrapped onto 2 lines
                elif re.search(r"\d+\.\d{2}", ln["text"]):
                    notes.append("Not read as an item: %s" % ln["text"])
                continue
            if not qty:
                qty = 1.0  # no quantity, or 0.00 printed with an amount (e.g. 'SHOP SALES'): 1 x amount
                if not price:
                    price = amount
            elif price is not None and abs(qty * price - amount) > max(1.0, abs(amount) * 0.01) and not discount:
                price = round(amount / qty, 4)  # the printed amount wins over a price that does not fit
            out.append({"desc": desc, "code": _norm(get("COLUMN CODE")), "qty": qty,
                        "price": price if price is not None else (amount / qty if qty else 0),
                        "amount": amount, "tax_raw": _norm(get("COLUMN TAX")), "page": pi,
                        "discount": round(discount, 2), "vat_amt": vat_amt})
            boxes.append((pi, box))
        if not eh:
            break  # without an end text, stay on the first page
    return out, boxes


# ---------------------------------------------------------------------------- whole invoice
def matches(tpl, text_doc):
    if (tpl.get("doc_type") or "auto").lower() == "invoice" and find_all(text_doc, "credit note"):
        return False  # an Invoice template never signs a credit note
    ids = [r for r in tpl.get("fields", []) if r["type"] == "DOCUMENT IDENTIFIER" and r.get("key")]
    if not ids:
        return None  # no identifier: only used when nothing else matches
    return all(find_all(text_doc, r["key"], r.get("case", True)) for r in ids)


def read(doc, tpl, own_tin=""):
    """Everything the designer shows and the signer needs."""
    rows = tpl.get("fields", [])
    vals, marks = {}, []
    for i, r in enumerate(rows):
        text, vbox, kbox, page = read_value(doc, r)
        found = bool(kbox or vbox) and (KIND.get(r["type"]) in ("key", "list", "col") or bool(text))
        marks.append({"i": i, "text": text, "vbox": vbox, "kbox": kbox, "page": page, "found": found})
        if r["type"] not in vals and found:
            vals[r["type"]] = text
    notes = []
    lines, line_boxes = item_lines(doc, rows, notes)
    doc_type = (tpl.get("doc_type") or "auto").lower()
    credit = doc_type == "credit" or (doc_type != "invoice" and "CREDIT NOTE IDENTIFIER" in vals)
    amounts = {t: num(vals.get(t)) for t in CHARGE_DEFAULTS if t in vals}
    amounts["VAT"] = num(vals.get("VAT")) if "VAT" in vals else None
    row_of = {r["type"]: r for r in rows}

    vat = amounts.get("VAT")
    free = (tpl.get("free_code") or "C").upper()

    def charge_line(t, amount, code=None):
        r = row_of.get(t, {})
        code = code or (r.get("tax") or CHARGE_DEFAULTS[t][0]).upper()
        name = r.get("item") or CHARGE_DEFAULTS[t][1]
        return {"desc": name, "code": "", "qty": 1.0, "price": amount, "amount": amount, "tax_raw": "",
                "tax": code, "incl": True, "charge": t}

    def sent(t):
        r = row_of.get(t)
        return bool(r.get("send", t not in NOT_SENT)) if r else False

    excluded = []
    for t in NOT_SENT + ("OTHER CHARGE",):
        a = amounts.get(t)
        if a and not sent(t):
            excluded.append((CHARGE_DEFAULTS[t][1], abs(a)))

    sale = []
    if lines and any(l["amount"] < 0 for l in lines) and not credit and (
            amounts.get("NET TAXABLE") or vat or amounts.get("TOTAL AMOUNT")):
        notes.append("Some item lines are credits or discounts, so the invoice is signed from its totals.")
        lines_for_sale = []
    else:
        lines_for_sale = lines
    if lines_for_sale:
        sale = [dict(l) for l in lines_for_sale]
        mode = "items"
        total_v = num(vals.get("TOTAL AMOUNT"))
        left_out = sum(a for _, a in excluded)
        got = sum(l["amount"] for l in sale)
        if total_v and left_out and got > 0:
            tol = max(0.05, abs(total_v) * 0.001)
            if abs(got - abs(total_v)) <= tol and abs(got - left_out - abs(total_v)) > tol:
                # the printed line amounts already include the service charge / levy: take it out of each line
                target = kra.r2(got - left_out)
                f = target / got
                done = 0.0
                for i, l in enumerate(sale):
                    new = kra.r2(l["amount"] * f) if i < len(sale) - 1 else kra.r2(target - done)
                    done = kra.r2(done + new)
                    l["price"] = kra.r2(new / l["qty"]) if l["qty"] else new
                    l["amount"] = new
                    l["discount"] = 0.0
                notes.append("Service charge / levy (%.2f) taken out of the line amounts." % left_out)
    else:
        net = amounts.get("NET TAXABLE")
        if net is None and vat:
            net = vat / 0.16
        if net:
            code = (row_of.get("NET TAXABLE", {}).get("tax") or "AUTO").upper()
            if code == "AUTO":  # from the VAT printed: 16%, 8% or none
                if vat is None:
                    code = "B"
                else:
                    pct = abs(vat) / abs(net) * 100
                    code = min((("B", 16.0), ("E", 8.0), (free, 0.0)), key=lambda c: abs(c[1] - pct))[0]
            rate = kra.TAX_RATES.get(code, 16.0)
            incl = abs(net) + abs(vat) if vat is not None else abs(net) * (100 + rate) / 100
            sale.append(charge_line("NET TAXABLE", kra.r2(incl), code))
        for t in ("NON TAXABLE", "ZERO RATED", "EXEMPT"):
            a = amounts.get(t)
            if a:
                sale.append(charge_line(t, abs(a)))
        mode = "totals"
        if not sale and amounts.get("TOTAL AMOUNT"):
            gross = abs(amounts["TOTAL AMOUNT"]) - sum(x for _, x in excluded)
            sale.append(charge_line("TOTAL AMOUNT", kra.r2(gross)))
            if sale[-1]["tax"] == "AUTO":
                sale[-1]["tax"] = ""  # worked out from the VAT printed (see taxes.resolve)
    for t in NOT_SENT + ("OTHER CHARGE",):
        a = amounts.get(t)
        if a and sent(t):
            sale.append(charge_line(t, abs(a)))
    if credit:
        for l in sale:
            l["amount"], l["price"] = abs(l["amount"]), abs(l["price"])
    pin = ""
    m = PIN_RE.search(vals.get("CUSTOMER TIN", "") or "")
    if m and m.group(1).upper() != (own_tin or "").upper():
        pin = m.group(1).upper()
    seller = PIN_RE.search(vals.get("DOCUMENT TIN", "") or "")
    seller_pin = seller.group(1).upper() if seller else ""
    if seller_pin and own_tin and seller_pin != own_tin.upper():
        notes.append("This invoice is from PIN %s, but this app signs for %s." % (seller_pin, own_tin.upper()))
    total = num(vals.get("TOTAL AMOUNT"))
    return {
        "invoice_no": ((vals.get("CREDIT NOTE NO") if credit else "") or vals.get("INVOICE NO") or "").strip(),
        "date": vals.get("DATE", ""),
        "customer_name": (vals.get("CUSTOMER NAME") or "")[:60],
        "customer_pin": pin,
        "total": abs(total) if (total is not None and credit) else total,
        "credit_note": credit,
        "original_invoice": vals.get("ORIGINAL INVOICE NO", "") if credit else "",
        "lines": sale,
        "items": lines,
        "mode": mode,
        "notes": notes,
        "marks": marks,
        "line_boxes": line_boxes,
        "values": vals,
        "seller_pin": seller_pin,
        "vat": abs(vat) if vat is not None else None,
        "excluded": excluded,
        "currency": norm_currency(vals.get("CURRENCY", "")),
        "rate": num(vals.get("EXCHANGE RATE")) if vals.get("EXCHANGE RATE") else None,
    }
