"""Sales reports from the signed invoices: on screen, Excel and PDF (BRV branded)."""
import json
import os
import sys
from datetime import datetime

from . import APP_NAME, VERSION, kra

NAVY, GOLD = "0A2348", "C38B2C"


def asset(name):
    here = getattr(sys, "_MEIPASS", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(here, "assets", name)


def rows(db, d_from, d_to, kind="ALL", currency="ALL"):
    """One dict per signed document. Credit notes are negative."""
    out = []
    for r in db.signed_between(d_from, d_to):
        if kind == "INVOICES" and r["kind"] != "S":
            continue
        if kind == "CREDIT NOTES" and r["kind"] != "R":
            continue
        cur = r["currency"] or "KES"
        if currency != "ALL" and cur != currency:
            continue
        try:
            p = json.loads(r["payload"] or "{}")
        except ValueError:
            p = {}
        sign = -1 if r["kind"] == "R" else 1
        d = {
            "date": (r["signed_at"] or "")[:10], "time": (r["signed_at"] or "")[11:16],
            "type": "Credit note" if r["kind"] == "R" else "Invoice",
            "invoice": r["trd_invc_no"], "kra_no": r["invc_no"], "cu": "%s/%s" % (r["sdc_id"] or "", r["invc_no"]),
            "orig": r["org_invc_no"] or "", "customer": r["cust_nm"] or "", "pin": r["cust_tin"] or "",
            "currency": cur, "rate": r["rate"] or 1.0,
            "amount_fc": sign * float(r["tot_amt_fc"] if r["tot_amt_fc"] is not None else r["tot_amt"] or 0),
            "excluded": sign * float(r["excluded"] or 0),
            "taxable": sign * float(r["tot_taxbl"] or 0), "vat": sign * float(r["tot_tax"] or 0),
            "total": sign * float(r["tot_amt"] or 0),
            "file": r["file_name"], "rcpt_sign": r["rcpt_sign"] or "",
        }
        for t in "ABCDE":
            d["taxbl_" + t] = sign * float(p.get("taxblAmt" + t) or 0)
            d["vat_" + t] = sign * float(p.get("taxAmt" + t) or 0)
        out.append(d)
    return out


def summary(data):
    s = {"count_inv": sum(1 for d in data if d["type"] == "Invoice"),
         "count_cn": sum(1 for d in data if d["type"] == "Credit note")}
    for k in ["taxable", "vat", "total", "excluded"] + ["taxbl_" + t for t in "ABCDE"] + ["vat_" + t for t in "ABCDE"]:
        s[k] = kra.r2(sum(d[k] for d in data))
    s["inv_total"] = kra.r2(sum(d["total"] for d in data if d["type"] == "Invoice"))
    s["cn_total"] = kra.r2(sum(d["total"] for d in data if d["type"] == "Credit note"))
    by_day = {}
    for d in data:
        b = by_day.setdefault(d["date"], {"date": d["date"], "count": 0, "taxable": 0.0, "vat": 0.0, "total": 0.0})
        b["count"] += 1
        for k in ("taxable", "vat", "total"):
            b[k] = kra.r2(b[k] + d[k])
    s["days"] = [by_day[k] for k in sorted(by_day)]
    by_cur = {}
    for d in data:
        c = by_cur.setdefault(d["currency"], {"currency": d["currency"], "count": 0, "amount_fc": 0.0, "total": 0.0})
        c["count"] += 1
        c["amount_fc"] = kra.r2(c["amount_fc"] + d["amount_fc"])
        c["total"] = kra.r2(c["total"] + d["total"])
    s["currencies"] = [by_cur[k] for k in sorted(by_cur)]
    return s


TAX_ROWS = [("A", "A - Exempt"), ("B", "B - 16%"), ("C", "C - Zero rated"), ("D", "D - Non-VAT"), ("E", "E - 8%")]
DOC_COLS = [("Date", "date", 11), ("Time", "time", 7), ("Type", "type", 11), ("Invoice no.", "invoice", 14),
            ("KRA no.", "kra_no", 8), ("Customer", "customer", 28), ("Customer PIN", "pin", 13),
            ("Currency", "currency", 8), ("Rate", "rate", 8), ("Amount (invoice currency)", "amount_fc", 14),
            ("Taxable KES", "taxable", 13), ("VAT KES", "vat", 12), ("Total to KRA KES", "total", 14),
            ("Levy/service not sent", "excluded", 12), ("CU invoice no.", "cu", 22), ("Original KRA no.", "orig", 10),
            ("PDF", "file", 28)]


def export_xlsx(path, data, d_from, d_to, business, filters):
    from openpyxl import Workbook
    from openpyxl.drawing.image import Image as XLImage
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    s = summary(data)
    wb = Workbook()
    head = PatternFill("solid", fgColor=NAVY)
    gold = Font(bold=True, color=GOLD, size=12)
    white = Font(bold=True, color="FFFFFF")
    thin = Border(bottom=Side(style="thin", color="DDDDDD"))
    money = "#,##0.00"

    ws = wb.active
    ws.title = "Summary"
    try:
        img = XLImage(asset("brv_logo.png"))
        img.width, img.height = 110, 90
        ws.add_image(img, "F1")
    except Exception:
        pass
    ws["A1"] = "Sales report - KRA eTIMS"
    ws["A1"].font = Font(bold=True, size=16, color=NAVY)
    ws["A2"] = business
    ws["A3"] = "Period: %s to %s   |   %s" % (d_from, d_to, filters)
    ws["A4"] = "Made %s by %s %s" % (datetime.now().strftime("%d/%m/%Y %H:%M"), APP_NAME, VERSION)
    r = 6
    for label, val in (("Invoices", s["count_inv"]), ("Credit notes", s["count_cn"]),
                       ("Invoices total (KES)", s["inv_total"]), ("Credit notes total (KES)", s["cn_total"]),
                       ("Net sales to KRA (KES)", s["total"]), ("Net VAT (KES)", s["vat"]),
                       ("Levies / service charge not sent (KES)", s["excluded"])):
        ws.cell(row=r, column=1, value=label).font = Font(bold=True)
        c = ws.cell(row=r, column=2, value=val)
        if isinstance(val, float):
            c.number_format = money
        r += 1
    r += 1
    ws.cell(row=r, column=1, value="By tax group").font = gold
    r += 1
    for c, h in enumerate(("Tax group", "Taxable KES", "VAT KES", "Total KES"), 1):
        x = ws.cell(row=r, column=c, value=h)
        x.fill, x.font = head, white
    for t, name in TAX_ROWS:
        r += 1
        ws.cell(row=r, column=1, value=name)
        for c, v in ((2, s["taxbl_" + t]), (3, s["vat_" + t]), (4, kra.r2(s["taxbl_" + t] + s["vat_" + t]))):
            ws.cell(row=r, column=c, value=v).number_format = money
    r += 1
    ws.cell(row=r, column=1, value="Total").font = Font(bold=True)
    for c, v in ((2, s["taxable"]), (3, s["vat"]), (4, s["total"])):
        x = ws.cell(row=r, column=c, value=v)
        x.number_format, x.font = money, Font(bold=True)
    r += 2
    ws.cell(row=r, column=1, value="By currency").font = gold
    r += 1
    for c, h in enumerate(("Currency", "Documents", "Amount (invoice currency)", "Total to KRA KES"), 1):
        x = ws.cell(row=r, column=c, value=h)
        x.fill, x.font = head, white
    for cu in s["currencies"]:
        r += 1
        ws.cell(row=r, column=1, value=cu["currency"])
        ws.cell(row=r, column=2, value=cu["count"])
        ws.cell(row=r, column=3, value=cu["amount_fc"]).number_format = money
        ws.cell(row=r, column=4, value=cu["total"]).number_format = money
    for col, w in zip("ABCDEF", (38, 16, 24, 18, 4, 16)):
        ws.column_dimensions[col].width = w

    wd = wb.create_sheet("Daily")
    for c, h in enumerate(("Date", "Documents", "Taxable KES", "VAT KES", "Total KES"), 1):
        x = wd.cell(row=1, column=c, value=h)
        x.fill, x.font = head, white
        wd.column_dimensions[x.column_letter].width = 16
    for i, d in enumerate(s["days"], 2):
        wd.cell(row=i, column=1, value=d["date"])
        wd.cell(row=i, column=2, value=d["count"])
        for c, k in ((3, "taxable"), (4, "vat"), (5, "total")):
            wd.cell(row=i, column=c, value=d[k]).number_format = money
    wd.freeze_panes = "A2"

    wi = wb.create_sheet("Documents")
    cols = DOC_COLS + [("Taxable %s" % n, "taxbl_" + t, 12) for t, n in TAX_ROWS] + \
        [("VAT %s" % n, "vat_" + t, 11) for t, n in TAX_ROWS if t in "BE"]
    for c, (h, _k, w) in enumerate(cols, 1):
        x = wi.cell(row=1, column=c, value=h)
        x.fill, x.font = head, white
        x.alignment = Alignment(wrap_text=True, vertical="center")
        wi.column_dimensions[x.column_letter].width = w
    wi.row_dimensions[1].height = 32
    for i, d in enumerate(data, 2):
        for c, (_h, k, _w) in enumerate(cols, 1):
            x = wi.cell(row=i, column=c, value=d[k])
            x.border = thin
            if isinstance(d[k], float) and k != "rate":
                x.number_format = money
    wi.freeze_panes = "A2"
    wi.auto_filter.ref = "A1:%s%d" % (wi.cell(row=1, column=len(cols)).column_letter, max(1, len(data) + 1))
    wb.save(path)


def export_pdf(path, data, d_from, d_to, business, filters):
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A4, landscape
    from reportlab.lib.styles import ParagraphStyle
    from reportlab.lib.units import mm
    from reportlab.platypus import Image, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle
    s = summary(data)
    navy, gold = colors.HexColor("#" + NAVY), colors.HexColor("#" + GOLD)
    doc = SimpleDocTemplate(path, pagesize=landscape(A4), leftMargin=12 * mm, rightMargin=12 * mm,
                            topMargin=10 * mm, bottomMargin=12 * mm, title="Sales report %s to %s" % (d_from, d_to),
                            author=APP_NAME)
    h1 = ParagraphStyle("h1", fontName="Helvetica-Bold", fontSize=16, textColor=navy, leading=20)
    h2 = ParagraphStyle("h2", fontName="Helvetica-Bold", fontSize=11, textColor=gold, leading=14, spaceBefore=8)
    small = ParagraphStyle("s", fontName="Helvetica", fontSize=8.5, leading=11, textColor=colors.HexColor("#444444"))
    fm = lambda v: "{:,.2f}".format(v)
    story = []
    try:
        logo = Image(asset("brv_logo.png"), width=26 * mm, height=21 * mm)
    except Exception:
        logo = ""
    head = Table([[[Paragraph("Sales report - KRA eTIMS", h1), Paragraph(business, small),
                    Paragraph("Period %s to %s  |  %s" % (d_from, d_to, filters), small),
                    Paragraph("Made %s by %s %s" % (datetime.now().strftime("%d/%m/%Y %H:%M"), APP_NAME, VERSION), small)],
                   logo]], colWidths=[230 * mm, 40 * mm])
    head.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("ALIGN", (1, 0), (1, 0), "RIGHT")]))
    story += [head, Spacer(1, 4 * mm)]
    style = TableStyle([("BACKGROUND", (0, 0), (-1, 0), navy), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"), ("FONTSIZE", (0, 0), (-1, -1), 8),
                        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F4F6FA")]),
                        ("ALIGN", (1, 1), (-1, -1), "RIGHT"), ("GRID", (0, 0), (-1, -1), 0.25, colors.HexColor("#D0D5DD"))])
    tot = [["Summary", "KES"], ["Invoices (%d)" % s["count_inv"], fm(s["inv_total"])],
           ["Credit notes (%d)" % s["count_cn"], fm(s["cn_total"])], ["Net sales to KRA", fm(s["total"])],
           ["Net VAT", fm(s["vat"])], ["Levy / service charge not sent", fm(s["excluded"])]]
    tg = [["Tax group", "Taxable", "VAT", "Total"]] + [
        [n, fm(s["taxbl_" + t]), fm(s["vat_" + t]), fm(s["taxbl_" + t] + s["vat_" + t])] for t, n in TAX_ROWS] + \
        [["Total", fm(s["taxable"]), fm(s["vat"]), fm(s["total"])]]
    cu = [["Currency", "Docs", "Amount", "To KRA KES"]] + [
        [c["currency"], str(c["count"]), fm(c["amount_fc"]), fm(c["total"])] for c in s["currencies"]]
    t1, t2, t3 = Table(tot, colWidths=[52 * mm, 30 * mm]), Table(tg, colWidths=[30 * mm, 28 * mm, 25 * mm, 28 * mm]), \
        Table(cu, colWidths=[18 * mm, 12 * mm, 28 * mm, 28 * mm])
    for t in (t1, t2, t3):
        t.setStyle(style)
    row = Table([[t1, t2, t3]], colWidths=[88 * mm, 117 * mm, 90 * mm])
    row.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0)]))
    story += [row, Paragraph("Documents", h2)]
    cols = [("Date", "date", 18), ("Type", "type", 18), ("Invoice", "invoice", 22), ("KRA", "kra_no", 11),
            ("Customer", "customer", 44), ("PIN", "pin", 22), ("Cur.", "currency", 10), ("Amount", "amount_fc", 24),
            ("Taxable KES", "taxable", 24), ("VAT KES", "vat", 20), ("Total KES", "total", 24), ("CU invoice no.", "cu", 34)]
    tbl = [[c[0] for c in cols]]
    for d in data:
        tbl.append([fm(d[k]) if isinstance(d[k], float) else str(d[k])[:34] for _, k, _ in cols])
    tbl.append(["", "", "", "", "TOTAL", "", "", "", fm(s["taxable"]), fm(s["vat"]), fm(s["total"]), ""])
    t = Table(tbl, colWidths=[w * mm for _, _, w in cols], repeatRows=1)
    st = TableStyle(style.getCommands() + [("ALIGN", (0, 1), (6, -1), "LEFT"), ("ALIGN", (11, 1), (11, -1), "LEFT"),
                                           ("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold")])
    t.setStyle(st)
    story.append(t)

    def footer(c, d):
        c.saveState()
        c.setFont("Helvetica", 7)
        c.setFillColor(colors.HexColor("#777777"))
        c.drawString(12 * mm, 6 * mm, "%s  -  BRV Integrated Systems  -  Software | Hardware | Integrations" % APP_NAME)
        c.drawRightString(landscape(A4)[0] - 12 * mm, 6 * mm, "Page %d" % d.page)
        c.restoreState()
    doc.build(story, onFirstPage=footer, onLaterPages=footer)


def export_csv(path, data):
    import csv
    with open(path, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow([h for h, _k, _w in DOC_COLS])
        for d in data:
            w.writerow([d[k] for _h, k, _w in DOC_COLS])
