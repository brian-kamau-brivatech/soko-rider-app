"""Sample invoices in different layouts (like QuickBooks and Sage print them)."""
import os
import sys

from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas


def qb_style(path, inv="1045", credit=False, items=None):
    c = canvas.Canvas(path, pagesize=A4)
    w, h = A4
    c.setFont("Helvetica-Bold", 18)
    c.drawString(40, h - 60, "CREDIT NOTE" if credit else "INVOICE")
    c.setFont("Helvetica", 10)
    c.drawString(40, h - 80, "Mtaani Supplies Ltd  |  PIN: P051111111A  |  Nakuru")
    c.drawString(380, h - 60, ("Credit Note #: CN-%s" % inv) if credit else ("Invoice #: %s" % inv))
    c.drawString(380, h - 75, "Date: 30/10/2026")
    if credit:
        c.drawString(380, h - 90, "Original Invoice #: 1045")
    c.drawString(40, h - 120, "Bill To:")
    c.drawString(40, h - 135, "Kamau Hardware Ltd")
    c.drawString(40, h - 150, "PIN: P051234567X")
    y = h - 190
    c.setFont("Helvetica-Bold", 10)
    for x, t in ((40, "Description"), (330, "Qty"), (400, "Rate"), (490, "Amount")):
        c.drawString(x, y, t)
    c.setFont("Helvetica", 10)
    items = items or [("Cement 50kg bag", 10, 750.00), ("Steel nails 4 inch", 5, 180.00),
                      ("Delivery charges", 1, 1100.00)]
    sub = 0
    for d, q, r in items:
        y -= 18
        a = q * r
        sub += a
        c.drawString(40, y, d)
        c.drawRightString(350, y, "%g" % q)
        c.drawRightString(440, y, "{:,.2f}".format(r))
        c.drawRightString(540, y, "{:,.2f}".format(a))
    vat = round(sub * 0.16, 2)
    y -= 30
    for label, v in (("Subtotal", sub), ("VAT 16%", vat), ("Total KES", sub + vat)):
        c.drawString(400, y, label)
        c.drawRightString(540, y, "{:,.2f}".format(v))
        y -= 16
    c.drawString(40, 80, "Thank you for your business.")
    c.save()


def sage_style(path):
    c = canvas.Canvas(path, pagesize=A4)
    w, h = A4
    c.setFont("Helvetica-Bold", 16)
    c.drawString(40, h - 60, "TAX INVOICE")
    c.setFont("Helvetica", 9)
    c.drawString(40, h - 78, "Rift Valley Agro Distributors   KRA PIN P051111111A")
    c.drawString(360, h - 60, "Inv No. SI-000233")
    c.drawString(360, h - 74, "Date 2026-10-30")
    c.drawString(40, h - 110, "Customer: Nakuru Agrovet")
    c.drawString(40, h - 124, "Customer PIN: A012345678B")
    y = h - 160
    c.setFont("Helvetica-Bold", 9)
    for x, t in ((40, "Code"), (90, "Description"), (300, "Qty"), (350, "Unit Price"), (430, "VAT"), (490, "Amount")):
        c.drawString(x, y, t)
    c.setFont("Helvetica", 9)
    rows = [("FRT01", "Maize seed H614 2kg", 4, 950.00, "16%"),
            ("FRT02", "DAP fertiliser 50kg", 2, 1250.00, "0%"),
            ("SRV09", "Soil testing service for", 1, 580.00, "16%")]
    total = 0
    for code, d, q, p, t in rows:
        y -= 15
        a = q * p
        total += a
        c.drawString(40, y, code)
        c.drawString(90, y, d)
        c.drawRightString(320, y, "%d" % q)
        c.drawRightString(410, y, "{:,.2f}".format(p))
        c.drawString(430, y, t)
        c.drawRightString(545, y, "{:,.2f}".format(a))
        if code == "SRV09":
            y -= 13
            c.drawString(90, y, "one farm plot")
    y -= 30
    c.drawString(380, y, "Total Amount Due")
    c.drawRightString(545, y, "{:,.2f}".format(total))
    c.save()


def hotel_style(path, inv="95487", lines=None, credit=False, pin="P000593855D"):
    """A hotel folio laid out like the lodge invoice: header block, Debit/Credit columns, totals at the bottom."""
    lines = lines or [("14/05", "A", "Kifaru Bar Beverage", 1250.00, None),
                      ("20/05", "P", "Beverage Allowance", None, 625.00),
                      ("20/05", "P", "Beverage - Discount", None, 625.00),
                      ("20/05", "A", "Room charge 1 night", 1250.00, None)]
    debit = sum(d or 0 for _, _, _, d, _ in lines)
    credit_sum = sum(c or 0 for _, _, _, _, c in lines)
    total = round(debit - credit_sum, 2)
    nett = round(total / 1.235, 2)
    vat, svc, levy = round(nett * 0.16, 2), round(nett * 0.055, 2), round(nett * 0.02, 2)
    nett = round(total - vat - svc - levy, 2)
    c = canvas.Canvas(path, pagesize=A4)
    w, h = A4
    c.setFont("Helvetica-Bold", 10)
    c.drawCentredString(w / 2, h - 50, "CREDIT NOTE" if credit else "ORIGINAL INVOICE")
    c.setFont("Helvetica", 7)
    c.drawString(60, h - 80, "VAT No: 16107")
    c.drawString(60, h - 88, "PIN No: %s" % pin)
    c.drawString(70, h - 125, "DOREEN KOMBO")
    c.drawString(70, h - 133, "KENYA")
    y = h - 115
    for k, v in (("INVOICE. No", inv), ("Page No.", "1"), ("Room No:", "8004"), ("Arrival", "14/05/2026"),
                 ("Departure", "20/05/2026")):
        c.drawString(330, y, k); c.drawString(375, y, ":"); c.drawString(385, y, v); y -= 8
    c.drawString(330, y, "Currency : KSH")
    c.drawString(70, h - 178, "CUST PIN: A002655384H")
    c.drawString(70, h - 190, "NGULIA SAFARI LODGE, MOMBASA, 20/05/2026 12:25:04 / 1 Cashier No: 18")
    c.drawString(70, h - 205, "Date"); c.drawString(110, h - 205, "Tax Description")
    c.drawString(330, h - 205, "Debit"); c.drawString(400, h - 205, "Credit")
    y = h - 222
    for d, t, desc, deb, cre in lines:
        c.drawString(70, y, d); c.drawString(110, y, t); c.drawString(122, y, desc)
        if deb: c.drawRightString(355, y, "{:,.2f}".format(deb))
        if cre: c.drawRightString(425, y, "{:,.2f}".format(cre))
        y -= 9
    y -= 20
    for k, v in (("NETT:", nett), ("VAT:", vat), ("Service Charge :", svc), ("Catering Levy", levy),
                 ("N Non VAT :", 0.0), ("Invoice Total :", total)):
        c.drawString(250, y, k); c.drawRightString(425, y, "{:,.2f}".format(v)); y -= 9
    if credit:
        c.drawString(70, y - 10, "Original Invoice: 95487")
    c.save()
    return {"total": total, "nett": nett, "vat": vat, "svc": svc, "levy": levy}


def shop_style(path, inv, items, vat_items=()):
    """A shop invoice without a VAT column: VAT is only printed as one total. items: (name, qty, price incl)."""
    c = canvas.Canvas(path, pagesize=A4)
    w, h = A4
    c.setFont("Helvetica-Bold", 14)
    c.drawString(40, h - 50, "DUKA MART LTD")
    c.setFont("Helvetica", 9)
    c.drawString(40, h - 66, "PIN: P051111111A   Tel 0700 000 000")
    c.drawString(40, h - 90, "Receipt No: %s" % inv)
    c.drawString(300, h - 90, "Date: 30/10/2026")
    y = h - 120
    c.drawString(40, y, "Item"); c.drawRightString(330, y, "Qty"); c.drawRightString(420, y, "Price"); c.drawRightString(520, y, "Amount")
    y -= 16
    total = vat = 0.0
    for name, qty, price in items:
        amt = round(qty * price, 2)
        total += amt
        if name in vat_items:
            vat += amt * 16 / 116
        c.drawString(40, y, name); c.drawRightString(330, y, "%g" % qty)
        c.drawRightString(420, y, "{:,.2f}".format(price)); c.drawRightString(520, y, "{:,.2f}".format(amt))
        y -= 14
    y -= 10
    c.drawString(300, y, "Total VAT"); c.drawRightString(520, y, "{:,.2f}".format(round(vat, 2))); y -= 14
    c.drawString(300, y, "TOTAL"); c.drawRightString(520, y, "{:,.2f}".format(round(total, 2)))
    c.save()


def till_receipt(path, voucher="SI145965", items=None, vat_line="0.00", pin="P051638299E"):
    """An 80 mm till receipt like the AFI PORK HOUSE one: page as tall as the text, nothing below."""
    items = items or [("Pork Choma 1/2 kg", 1, 550.00), ("Ugali", 1, 100.00)]
    total = sum(q * p for _, q, p in items)
    w, h = 227, 430 + 18 * len(items)
    c = canvas.Canvas(path, pagesize=(w, h))
    y = h - 30

    def line(text, x=None, size=8, bold=False, right=None):
        c.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        if right is not None:
            c.drawRightString(right, y, text)
        elif x is None:
            c.drawCentredString(w / 2, y, text)
        else:
            c.drawString(x, y, text)
    line("AFI PORK HOUSE MUTHIGA", size=10, bold=True); y -= 16
    line("MOBILE: 0791306821, 0115776960"); y -= 14
    line("MPESA TILL NO: 928650", bold=True); y -= 12
    line("KRA PIN: %s" % pin, bold=True); y -= 16
    line("BUYER'S PIN:", 12, bold=True); y -= 13
    line("Party : A Muthiga Sales", 20); y -= 13
    line("Waiter : Marline Lwali", 20); y -= 18
    line("PAYMENT SETTLEMENT", bold=True, size=9); y -= 16
    line("Voucher No : %s" % voucher, 12, bold=True); y -= 14
    line("Voucher Date : 14-Apr-25 1:07:07 PM", 12); y -= 18
    line("ITEM", 12, bold=True); line("QTY", 150, bold=True); line("AMOUNT", right=215, bold=True); y -= 15
    for name, q, p in items:
        line(name, 10, size=7); line("%g" % q, 158, size=7); line("{:,.2f}".format(q * p), right=215, size=7); y -= 18
    line("Total Amount :", 12, size=11, bold=True); line("{:,.2f}".format(total), right=215, size=11, bold=True); y -= 18
    line("16% VAT :", 14, size=9, bold=True); line(vat_line, right=200, size=9, bold=True); y -= 15
    line("Mpesa Paid :", 14, size=9, bold=True); line("{:,.2f}".format(total), right=200, size=9, bold=True); y -= 15
    line("Cash Paid :", 14, size=9, bold=True); line("0.00", right=200, size=9, bold=True); y -= 20
    line("END :", 18, size=11, bold=True); line("{:,.2f}".format(total), right=215, size=11, bold=True); y -= 18
    line("POWERED @ www.teletrading.co.ke, 0715619593", size=6)
    c.save()


def detailed_style(path, inv="INV-501", with_amount=True, credit=False, orig=""):
    """Columns: No, TAX, Item Description, Qty, Unit Price, Tax, Discount Rt, Discount Amt, Amount (prices excl VAT)."""
    items = [("B", "Cooking oil 5L", 2, 1500.00, 10), ("C", "Fresh milk 500ml", 10, 60.00, 0),
             ("B", "Detergent 1kg", 3, 400.00, 5)]
    c = canvas.Canvas(path, pagesize=A4)
    w, h = A4
    c.setFont("Helvetica-Bold", 14)
    c.drawString(40, h - 50, "WHOLESALE HUB LTD")
    c.setFont("Helvetica", 9)
    c.drawString(40, h - 66, "PIN: P051111111A")
    c.drawString(40, h - 90, ("Credit Note No: %s" if credit else "Invoice No: %s") % inv)
    if credit:
        c.drawString(300, h - 90, "Original Invoice: %s" % orig)
        c.setFont("Helvetica-Bold", 12); c.drawString(400, h - 50, "CREDIT NOTE"); c.setFont("Helvetica", 9)
    xs = [40, 60, 85, 250, 305, 350, 400, 465, 540]
    heads = ["No", "TAX", "Item Description", "Qty", "Unit Price", "Tax", "Discount Rt", "Discount Amt", "Amount"]
    if not with_amount:
        heads, xs = heads[:-1], xs[:-1]
    y = h - 120
    c.setFont("Helvetica-Bold", 7.5)
    for x, t in zip(xs, heads):
        (c.drawRightString if t in ("Qty", "Unit Price", "Tax", "Discount Rt", "Discount Amt", "Amount") else c.drawString)(x, y, t)
    c.setFont("Helvetica", 7.5)
    y -= 14
    tot = vat_t = 0
    for i, (code, name, q, p, rt) in enumerate(items, 1):
        gross = q * p; disc = round(gross * rt / 100, 2); net = gross - disc
        vat = round(net * (0.16 if code == "B" else 0), 2)
        tot += net + vat; vat_t += vat
        vals = [str(i), code, name, "%g" % q, "{:,.2f}".format(p), "{:,.2f}".format(vat), "%g" % rt,
                "{:,.2f}".format(disc), "{:,.2f}".format(net)]
        if not with_amount:
            vals = vals[:-1]
        for x, t, hd in zip(xs, vals, heads):
            (c.drawRightString if hd in ("Qty", "Unit Price", "Tax", "Discount Rt", "Discount Amt", "Amount") else c.drawString)(x, y, t)
        y -= 13
    y -= 10
    c.drawString(380, y, "Total VAT"); c.drawRightString(545, y, "{:,.2f}".format(vat_t)); y -= 13
    c.drawString(380, y, "Total"); c.drawRightString(545, y, "{:,.2f}".format(tot))
    c.save()
    return round(tot, 2), round(vat_t, 2)


def kslh_style(path, inv="128211", nett=239967.09, vat=38394.73, svc=14338.83, levy=4799.34, total=297500.00,
               pin="P000593855D"):
    """Like the Mombasa Beach Hotel folio: VAT Analysis (A 16%, Z 0%, E Exempt, N Non VAT) + Other Levies."""
    c = canvas.Canvas(path, pagesize=A4)
    w, h = A4
    f = lambda: "{:,.2f}"
    c.setFont("Helvetica-Bold", 9)
    c.drawString(330, h - 60, "KENYA SAFARI LODGES & HOTELS LIMITED"); c.drawString(390, h - 72, "MOMBASA BEACH HOTEL")
    c.drawString(40, h - 120, pin); c.drawString(40, h - 132, "VAT No: 0016108A")
    c.setFont("Helvetica-Bold", 12); c.drawString(330, h - 160, "ORIGINAL INVOICE")
    c.setFont("Helvetica", 9)
    c.drawString(45, h - 180, "MERU COUNTY GOVERNMENT"); c.drawString(45, h - 191, "P.O BOX"); c.drawString(45, h - 202, "KENYA")
    c.drawString(45, h - 230, "CUST PIN : P051418782S")
    y = h - 185
    for k, v in (("INVOICE. No", inv), ("Page No.", "2"), ("Room No:", "9001"), ("Arrival", "04/02/2026"), ("Departure", "05/02/2026")):
        c.drawString(390, y, k); c.drawString(450, y, ":"); c.drawString(460, y, v); y -= 11
    c.drawString(45, h - 275, "MOMBASA BEACH HOTEL, 11/02/2026 15:44:56 / 1 Cashier No: 51"); c.drawString(390, h - 275, "Currency :  KSH")
    c.drawString(45, h - 290, "Date"); c.drawString(90, h - 290, "Tax Description"); c.drawString(400, h - 290, "Debit"); c.drawString(470, h - 290, "Credit")
    c.drawString(45, h - 310, "11/02"); c.drawString(100, h - 310, "P"); c.drawString(150, h - 310, "PAY - Cash collections")
    c.drawRightString(500, h - 320, "1.00")
    c.drawString(330, h - 345, "Total"); c.drawRightString(440, h - 345, f().format(total)); c.drawRightString(500, h - 345, "0.00")
    c.drawString(330, h - 365, "Balance KSH"); c.drawRightString(440, h - 365, f().format(total))
    c.setFont("Helvetica-Bold", 8); c.drawString(360, h - 395, "VAT Analysis KES"); c.setFont("Helvetica", 8)
    c.drawString(290, h - 410, "Code"); c.drawString(370, h - 410, "Nett"); c.drawString(450, h - 410, "VAT")
    y = h - 425
    for k, n_, v_ in (("A VAT 16% :", nett, vat), ("Z VAT 0% :", 0, 0), ("E VAT Exempt :", 0, 0), ("N Non VAT :", 0, 0)):
        c.drawString(290, y, k); c.drawString(360, y, f().format(n_)); c.drawString(450, y, f().format(v_)); y -= 11
    c.drawString(290, y - 2, "Total"); c.drawString(360, y - 2, "NETT: " + f().format(nett)); c.drawString(450, y - 2, "VAT: " + f().format(vat))
    c.setFont("Helvetica-Bold", 8); c.drawString(380, y - 25, "Other Levies KES"); c.setFont("Helvetica", 8)
    c.drawString(290, y - 40, "Service Charge :"); c.drawString(450, y - 40, f().format(svc))
    c.drawString(290, y - 51, "Catering Levy :"); c.drawString(450, y - 51, f().format(levy))
    c.drawString(290, y - 72, "Invoice Total :  " + f().format(total)); c.drawString(440, y - 72, "Total Taxes : " + f().format(vat + svc + levy))
    c.setFont("Helvetica", 7)
    c.drawString(40, y - 100, "I AGREE THAT MY LIABILITY FOR THIS BILL IS NOT WAIVED AND AGREE TO BE HELD PERSONALLY LIABLE")
    c.drawString(40, y - 125, "Guest Signature: ______________"); c.drawString(330, y - 125, "Cashier Signature: ______________")
    c.save()


if __name__ == "__main__":
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    qb_style(os.path.join(out, "QB Invoice 1045.pdf"))
    sage_style(os.path.join(out, "Sage SI-000233.pdf"))
    qb_style(os.path.join(out, "QB Credit CN-1045.pdf"), inv="1045", credit=True,
             items=[("Steel nails 4 inch", 2, 180.00)])
    hotel_style(os.path.join(out, "Lodge 95487.pdf"))
    print("samples in", out)
