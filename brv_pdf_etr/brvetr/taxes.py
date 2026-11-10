"""Which KRA tax code each line gets, and a check against the VAT printed on the invoice.

Order for every line:
  1. a code fixed by the template row (totals: NET TAXABLE = B, ZERO RATED = C ...)
  2. the VAT column on the PDF (through the template's 'VAT column -> code' list)
  3. the item register (Items tab, Excel upload, or the code the item was signed with before),
     then the word list in Settings ("milk=C, eggs=A": words found in the description)
  4. the template default; with AUTO it is worked out from the VAT printed on the invoice:
     no VAT printed -> the lines are VAT-free (zero-rated or exempt, as the template says);
     VAT = 16% of them -> 16%. If neither fits, the invoice is not signed and the reason says
     which items need a code.
Finally the VAT of all lines must equal the VAT printed on the invoice (when the template reads it).
"""
from . import kra

AUTO = "AUTO"
CODES = ["B", "A", "C", "D", "E"]


def parse_rules(text):
    """'milk=C, eggs = A' -> [('milk', 'C'), ('eggs', 'A')], longest words first."""
    out = []
    for part in (text or "").replace(";", ",").replace("\n", ",").split(","):
        if "=" in part:
            w, c = part.rsplit("=", 1)
            w, c = w.strip().lower(), c.strip().upper()
            if w and c in CODES:
                out.append((w, c))
    out.sort(key=lambda x: -len(x[0]))
    return out


def column_code(tpl, raw):
    if not raw:
        return None
    mp = {str(k).upper(): v for k, v in (tpl.get("tax_map") or {}).items()}
    key = raw.upper().replace(" ", "")
    for k in (key, key.rstrip("%")):
        if k in mp:
            return mp[k]
    if key in CODES:
        return key
    return None


def _code_from_vat(ln, tpl):
    amt, vat = abs(ln["amount"]), abs(ln["vat_amt"] or 0)
    incl = ln["incl"] if "incl" in ln else bool(tpl.get("prices_include_vat", True))
    base = amt - vat if incl else amt
    if base <= 0:
        return None
    pct = vat / base * 100
    free = (tpl.get("free_code") or "C").upper()
    for code, rate in (("B", 16.0), ("E", 8.0), (free, 0.0)):
        if abs(pct - rate) <= 0.6 or abs(vat - base * rate / 100) <= 0.05:
            return code
    return None


def line_vat(amount, code, incl):
    rate = kra.TAX_RATES.get(code, 0.0)
    return amount * rate / (100 + rate) if incl else amount * rate / 100


def resolve(parsed, tpl, rules=(), known=None):
    """Sets ln['tax'] on every line. Returns (problems, notes).
    known(desc) -> code an item was registered with at KRA before (or None)."""
    lines = parsed["lines"]
    problems, notes = [], []
    unknown = []
    for ln in lines:
        code = (ln.get("tax") or "").upper()
        if code == AUTO:
            code = ""
        if not code:
            code = column_code(tpl, ln.get("tax_raw"))
        if not code and ln.get("vat_amt") is not None and ln.get("amount"):
            code = _code_from_vat(ln, tpl)  # the line's own VAT amount: 16% -> B, 8% -> E, 0 -> VAT-free
        if not code and known and (ln.get("desc") or ln.get("code")):
            code = known(ln)  # the item register (Items tab / Excel upload / signed before)
        if not code:
            d = (ln.get("desc") or "").lower()
            code = next((c for w, c in rules if w in d), None)
        if code:
            ln["tax"] = code
        else:
            unknown.append(ln)
    incl = lambda ln: ln["incl"] if "incl" in ln else bool(tpl.get("prices_include_vat", True))
    printed = parsed.get("vat")
    if printed is not None:
        printed = abs(printed)
    known_vat = sum(line_vat(abs(ln["amount"]), ln["tax"], incl(ln)) for ln in lines if ln not in unknown)
    tol = max(1.0, 0.05 * len(lines))
    if unknown:
        default = (tpl.get("default_tax") or "B").upper()
        free = (tpl.get("free_code") or "C").upper()
        if default != AUTO:
            pick = default
        elif printed is None:
            pick = "B"
            notes.append("No VAT amount is read by this template, so lines without a VAT code were taken as 16%.")
        else:
            pick = None
            for cand in ("B", free):
                v = known_vat + sum(line_vat(abs(ln["amount"]), cand, incl(ln)) for ln in unknown)
                if abs(v - printed) <= tol:
                    pick = cand
                    break
            if pick is None:
                names = ", ".join("'%s'" % (ln.get("desc") or "?") for ln in unknown[:6])
                problems.append("The invoice has some VAT-free and some 16%% items, and these have no VAT code: %s. "
                                "Add them to 'VAT-free items' in Settings (e.g. milk=C), or read the VAT column "
                                "in the template." % names)
                pick = "B"
        for ln in unknown:
            ln["tax"] = pick
    vat = sum(line_vat(abs(ln["amount"]), ln["tax"], incl(ln)) for ln in lines)
    parsed["vat_calc"] = kra.r2(vat)
    if printed is not None and lines and not problems and abs(vat - printed) > tol:
        problems.append("The VAT on the invoice is %.2f but the lines give %.2f. Check the VAT codes of the items "
                        "(VAT column in the template, or 'VAT-free items' in Settings)." % (printed, vat))
    return problems, notes
