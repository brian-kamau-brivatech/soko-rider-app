"""KRA eTIMS rules: tax maths and the exact VSCU sales payload (same as BRV POS)."""
import re
from datetime import datetime
from decimal import ROUND_HALF_UP, Decimal

TAX_RATES = {"A": 0.0, "B": 16.0, "C": 0.0, "D": 0.0, "E": 8.0}
TAX_NAMES = {"A": "A-Exempt", "B": "B-16%", "C": "C-Zero rated", "D": "D-Non VAT", "E": "E-8%"}
PAYMENT_TYPES = {"01": "Cash", "02": "Credit", "03": "Cash/Credit", "04": "Bank cheque",
                 "05": "Debit & credit card", "06": "Mobile money", "07": "Other"}


def r2(v):
    """Round to 2 decimals, half up (KRA wants 2 decimals everywhere)."""
    return float(Decimal(str(v)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def etims_dt(t):
    return t.strftime("%Y%m%d%H%M%S")


def hyphenate(s, every=4):
    v = (s or "").replace("-", "")
    return "-".join(v[i:i + every] for i in range(0, len(v), every))


def receipt_url(tin, bhf_id, rcpt_sign):
    return ("https://etims.kra.go.ke/common/link/etims/receipt/indexEtimsReceiptData?Data=%s%s%s"
            % (tin, bhf_id, (rcpt_sign or "").replace("-", "")))


def make_item_code(origin, item_type, pkg, qty, seq):
    """KE2NTU00000000000039 style code (same scheme as Odoo and BRV POS)."""
    prefix = "%s%s%s%s" % (origin, item_type, pkg, qty)
    n = str(seq)
    return prefix.ljust(20 - len(n), "0") + n


def expected_invoice_no(msg):
    m = re.search(r"expected[^0-9]*(\d+)", msg or "", re.I)
    return int(m.group(1)) if m else None


class Line:
    """One invoice line. price_incl = unit price including VAT."""

    def __init__(self, item_cd, item_cls_cd, name, pkg_unit, qty_unit, tax, qty, price_incl, total=None, discount=0.0):
        self.item_cd = item_cd
        self.item_cls_cd = item_cls_cd
        self.name = name
        self.pkg_unit = pkg_unit
        self.qty_unit = qty_unit
        self.tax = tax
        self.qty = r2(qty)
        self.price_incl = r2(price_incl)
        rate = TAX_RATES.get(tax, 0.0)
        # The line total printed on the invoice wins (avoids 1-cent differences).
        self.gross = r2(total) if total is not None else r2(self.qty * self.price_incl)
        self.total = self.gross
        self.taxable = r2(self.total * 100 / (100 + rate))
        self.tax_amt = r2(self.total - self.taxable)
        self.discount = r2(discount or 0)  # VAT inclusive discount already taken off the total

    def to_json(self, seq, incl_vat=True):
        """incl_vat: send prc/splyAmt VAT inclusive (BRV POS default); taxblAmt is always without VAT."""
        rate = TAX_RATES.get(self.tax, 0.0)
        if incl_vat and self.discount > 0:
            # discount sent as KRA wants it: supply amount before discount, then the discount
            sply = r2(self.gross + self.discount)
            amounts = {"prc": r2(sply / self.qty) if self.qty else self.price_incl, "splyAmt": sply,
                       "dcRt": r2(self.discount / sply * 100) if sply else 0.0, "dcAmt": self.discount}
        elif incl_vat:
            amounts = {"prc": r2(self.gross / self.qty) if self.qty else self.price_incl,
                       "splyAmt": self.gross, "dcRt": 0.0, "dcAmt": 0.0}
        else:
            sply_ex = r2((self.gross + self.discount) * 100 / (100 + rate))
            dc = r2(sply_ex - self.taxable)
            amounts = {"prc": r2(sply_ex / self.qty) if self.qty else 0.0, "splyAmt": sply_ex,
                       "dcRt": r2(dc / sply_ex * 100) if (sply_ex and self.discount) else 0.0, "dcAmt": dc}
        return {
            "itemSeq": seq,
            "itemCd": self.item_cd,
            "itemClsCd": self.item_cls_cd,
            "itemNm": self.name[:200],
            "pkgUnitCd": self.pkg_unit,
            "pkg": self.qty,
            "qtyUnitCd": self.qty_unit,
            "qty": self.qty,
            **amounts,
            "taxblAmt": self.taxable,  # taxable amount = without VAT
            "taxAmt": self.tax_amt,
            "totAmt": self.total,
            "taxTyCd": self.tax,
            "isrccCd": "", "isrccNm": "", "isrcRt": "", "isrcAmt": "",
        }


def build_sale_payload(tin, bhf_id, invc_no, trd_invc_no, lines, payment, when, credit_note=False,
                       org_invc_no=0, refund_reason="06", cust_tin="", cust_nm="", user="BRV PDF ETR",
                       incl_vat=True):
    items = [l.to_json(i + 1, incl_vat) for i, l in enumerate(lines)]
    by_tax = {t: {"taxbl": 0.0, "tax": 0.0} for t in "ABCDE"}
    for it in items:
        b = by_tax[it["taxTyCd"]]
        b["taxbl"] = r2(b["taxbl"] + it["taxblAmt"])
        b["tax"] = r2(b["tax"] + it["taxAmt"])
    cfm = etims_dt(when)
    p = {
        "tin": tin,
        "bhfId": bhf_id,
        "invcNo": invc_no,
        "trdInvcNo": (trd_invc_no or "")[:50],
        "orgInvcNo": org_invc_no if credit_note else 0,
        "cfmDt": cfm,
        "pmtTyCd": payment,
        "rcptTyCd": "R" if credit_note else "S",
        "salesTyCd": "N",
        "custTin": (cust_tin or "")[:11],
        "custNm": (cust_nm or "")[:60],
        "custMblNo": "",
        "salesSttsCd": "02",
        "salesDt": cfm[:8],
        "totItemCnt": len(items),
    }
    if credit_note:
        p["rfdRsnCd"] = refund_reason
    for t in "ABCDE":
        p["taxblAmt" + t] = by_tax[t]["taxbl"]
    for t in "ABCDE":
        p["taxRt" + t] = TAX_RATES[t]
    for t in "ABCDE":
        p["taxAmt" + t] = by_tax[t]["tax"]
    p.update({
        "totTaxblAmt": r2(sum(it["taxblAmt"] for it in items)),
        "totTaxAmt": r2(sum(it["taxAmt"] for it in items)),
        "totAmt": r2(sum(it["totAmt"] for it in items)),
        "prchrAcptcYn": "Y",
        "regrId": "1", "regrNm": user, "modrId": "1", "modrNm": user,
        "receipt": {"custTin": (cust_tin or "")[:11], "rcptPbctDt": cfm, "prchrAcptcYn": "N",
                    "custMblNo": "", "adrs": ""},
        "itemList": items,
    })
    return p


def now():
    return datetime.now()
