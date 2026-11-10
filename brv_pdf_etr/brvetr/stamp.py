"""Stamps the KRA eTIMS details (CU number, signature, QR code) onto the invoice PDF."""
import io

from pypdf import PdfReader, PdfWriter
from reportlab.graphics import renderPDF
from reportlab.graphics.barcode.qr import QrCodeWidget
from reportlab.graphics.shapes import Drawing
from reportlab.lib.colors import HexColor, black, white
from reportlab.pdfgen import canvas

from .kra import hyphenate

MM = 72 / 25.4


def stamp_lines(info):
    """info: sdc_id, invc_no, rcpt_no, tot_rcpt_no, intrl_data, rcpt_sign, when (datetime), credit, url."""
    when = info["when"]
    return [
        ("Date", when.strftime("%d/%m/%Y  %H:%M:%S")),
        ("SCU ID", info.get("sdc_id") or ""),
        ("CU Invoice No.", "%s/%s" % (info.get("sdc_id") or "", info.get("invc_no"))),
        ("Receipt No.", "%s/%s %s" % (info.get("rcpt_no") or "", info.get("tot_rcpt_no") or "",
                                       "NC" if info.get("credit") else "NS")),
        ("Internal data", hyphenate(info.get("intrl_data") or "")),
        ("Signature", hyphenate(info.get("rcpt_sign") or "")),
    ] + ([("Currency", "%s at %s = KES (sent to KRA in KES)" % (info["currency"], "{:,.4f}".format(info["rate"]).rstrip("0").rstrip(".")))]
         if (info.get("currency") or "KES") != "KES" else [])


def _free_spot(page_w, page_h, width, height, words, margin):
    """First place (bottom-right, bottom-left, then upwards) where the box covers no text."""
    def clear(x, y):
        for (x0, y0, x1, y1) in words:
            if x < x1 + 2 and x + width > x0 - 2 and y < y1 + 2 and y + height > y0 - 2:
                return False
        return True
    step = 4 * MM
    y = margin
    while y + height <= page_h - margin:
        for x in (page_w - width - margin, margin, (page_w - width) / 2):
            if clear(x, y):
                return x, y
        y += step
    return None


def place(page_w, page_h, width, height, cfg, words=None, anchor_box=None):
    """Bottom-left corner (PDF points) of the KRA box.

    anchor: auto (first empty spot) | fixed (x_mm, y_mm = box top-left from the page top-left) |
            text (x_mm, y_mm = box top-left from the top-left of the anchor text, e.g. 'Invoice Total') |
            after (under the last line of text, x_mm from the left) | bottom-right, bottom-left, bottom-center,
            top-right, top-left (x_mm, y_mm = margins).
    words / anchor_box are in PDF points with the origin at the bottom-left.
    """
    anchor = (cfg.get("anchor") or "auto").lower()
    dx, dy = float(cfg.get("x_mm") or 0) * MM, float(cfg.get("y_mm") or 0) * MM
    clamp = lambda x, y: (min(max(x, 0), max(0, page_w - width)), min(max(y, 0), max(0, page_h - height)))
    if anchor == "fixed":
        return clamp(dx, page_h - dy - height)
    if anchor == "text":
        if anchor_box:
            ax0, _ay0, _ax1, ay1 = anchor_box  # ay1 = top of the text
            return clamp(ax0 + dx, ay1 - dy - height)
        anchor = "auto"  # text not on this invoice: fall back to an empty spot
    if anchor == "after":
        low = min([w[1] for w in (words or [])] or [page_h])
        y = low - 4 * MM - height
        if y >= 3 * MM:
            return clamp(dx or (page_w - width) / 2, y)
        anchor = "auto"
    if anchor == "auto":
        spot = _free_spot(page_w, page_h, width, height, words or [], max(dx, dy, 8 * MM))
        if spot:
            return spot
        anchor = "bottom-right"
    x = page_w - width - dx if "right" in anchor else (page_w - width) / 2 + dx if "center" in anchor else dx
    y = page_h - height - dy if anchor.startswith("top") else dy
    return clamp(x, y)


def box_size(page_w, page_h, info, cfg):
    """(width, height) in points of the KRA block for this template (used by the designer to drag it)."""
    if is_clean(cfg):
        return clean_size(page_w, info, cfg)
    return _overlay(page_w, page_h, info, dict(cfg, anchor="fixed", x_mm=0, y_mm=0), size_only=True)


def _overlay(page_w, page_h, info, cfg, words=None, anchor_box=None, size_only=False):
    width = max(55.0, float(cfg.get("width_mm") or 75)) * MM
    pad = 2.2 * MM
    qr = 21 * MM
    label_size, value_size = 6.3, 6.6
    rows = stamp_lines(info)
    text_w = width - qr - 3 * pad

    c_buf = io.BytesIO()
    c = canvas.Canvas(c_buf, pagesize=(page_w, page_h))

    # Wrap long values (internal data / signature) to the text column.
    wrapped = []
    for label, value in rows:
        parts, cur = [], ""
        for ch in value:
            if c.stringWidth(cur + ch, "Helvetica-Bold", value_size) > text_w - 1:
                parts.append(cur)
                cur = ch
            else:
                cur += ch
        parts.append(cur)
        wrapped.append((label, parts))
    body_h = sum(label_size + 1.5 + len(p) * (value_size + 1.2) for _, p in wrapped)
    title_h = 10
    height = max(qr, body_h) + title_h + 2 * pad
    if size_only:
        return width, height

    x, y = place(page_w, page_h, width, height, cfg, words, anchor_box)

    c.setFillColor(white)
    c.setStrokeColor(HexColor("#0A2348"))
    c.setLineWidth(0.8)
    c.roundRect(x, y, width, height, 4, stroke=1, fill=1)
    c.setFillColor(HexColor("#0A2348"))
    c.rect(x, y + height - title_h - 2, width, title_h + 2, stroke=0, fill=1)
    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 7.5)
    c.drawString(x + pad, y + height - title_h + 1.2,
                 "KRA eTIMS  -  SCU INFORMATION%s" % ("  (CREDIT NOTE)" if info.get("credit") else ""))

    # QR code (KRA receipt check link)
    w = QrCodeWidget(info["url"], barLevel="L")
    b = w.getBounds()
    bw, bh = b[2] - b[0], b[3] - b[1]
    d = Drawing(qr, qr, transform=[qr / bw, 0, 0, qr / bh, 0, 0])
    d.add(w)
    renderPDF.draw(d, c, x + width - qr - pad, y + pad + (height - title_h - 2 * pad - qr) / 2)

    ty = y + height - title_h - pad - label_size
    for label, parts in wrapped:
        c.setFillColor(HexColor("#555555"))
        c.setFont("Helvetica", label_size)
        c.drawString(x + pad, ty, label)
        ty -= value_size + 1.2
        c.setFillColor(black)
        c.setFont("Helvetica-Bold", value_size)
        for p in parts:
            c.drawString(x + pad, ty, p)
            ty -= value_size + 1.2
        ty -= 0.3
    c.save()
    return PdfReader(io.BytesIO(c_buf.getvalue())).pages[0]


RECEIPT_MAX_W = 300  # points (~105 mm): narrower pages are till rolls (block goes under the last line)


def is_clean(cfg):
    """clean = plain centred CU block like a KRA receipt (default); box = framed box."""
    return (cfg.get("style") or "clean").lower() != "box"


def receipt_lines(info, title=None):
    """The clean block, laid out like KRA device receipts and following the TIS specification (6.23):
    'SCU Information', Date dd/mm/yyyy Time hh:mm:ss, CU ID, CU invoice no. KRACU.../n, receipt counter 'A/B RT',
    internal data and signature with a dash every 4 characters, QR code; then the TIS (this app's) information."""
    when = info["when"]
    sdc = info.get("sdc_id") or ""
    rt = "NC" if info.get("credit") else "NS"
    out = [("h", title or "SCU INFORMATION"),
           ("t", "Date: %s  Time: %s" % (when.strftime("%d/%m/%Y"), when.strftime("%H:%M:%S"))),
           ("t", "CU ID: %s" % sdc),
           ("t", "CU INVOICE NO: %s/%s" % (sdc, info.get("invc_no"))),
           ("t", "Receipt Number: %s/%s %s" % (info.get("rcpt_no") or "", info.get("tot_rcpt_no") or "", rt)),
           ("t", "Internal Data: %s" % hyphenate(info.get("intrl_data") or "")),
           ("t", "Receipt Signature: %s" % hyphenate(info.get("rcpt_sign") or "")),
           ("qr", ""),
           ("h", "TIS INFORMATION"),
           ("t", "%s NUMBER: %s" % ("CREDIT NOTE" if info.get("credit") else "INVOICE", info.get("invc_no") or "")),
           ("t", "DATE: %s  TIME: %s" % (when.strftime("%d/%m/%Y"), when.strftime("%H:%M:%S")))]
    if info.get("credit"):
        out.insert(1, ("t", "CREDIT NOTE"))
    if (info.get("currency") or "KES") != "KES":
        out.append(("t", "%s at %s = KES (sent to KRA in KES)" % (info["currency"], info["rate"])))
    return out


def _clean_width(page_w, cfg):
    if page_w <= RECEIPT_MAX_W:
        return page_w - 6 * MM
    return max(55.0, float(cfg.get("width_mm") or 75)) * MM


def _clean_heights(width, lines):
    qr = min(26 * MM, width * 0.6)
    return [qr + 5 if kind == "qr" else 11.5 if kind == "h" else 8.8 for kind, _t in lines], qr


def clean_size(page_w, info, cfg):
    w = _clean_width(page_w, cfg)
    hs, _qr = _clean_heights(w, receipt_lines(info, cfg.get("title")))
    return w, sum(hs) + 4 * MM


def layout(page_w, page_h, info, cfg, words=None, anchor_box=None):
    """(x, y_bottom, width, height) of the KRA block in PDF points. y_bottom < 0 = the page must grow."""
    anchor = (cfg.get("anchor") or "auto").lower()
    if is_clean(cfg):
        bw, bh = clean_size(page_w, info, cfg)
        if page_w <= RECEIPT_MAX_W and anchor in ("auto", "after"):
            # till roll: right under the last line, centred; the page grows if needed
            low = min([w[1] for w in (words or [])] or [page_h])
            return (page_w - bw) / 2, low - 4 * MM - bh, bw, bh
        if anchor == "after":
            low = min([w[1] for w in (words or [])] or [page_h])
            return (page_w - bw) / 2, low - 4 * MM - bh, bw, bh
    else:
        bw, bh = _overlay(page_w, page_h, info, dict(cfg, anchor="fixed", x_mm=0, y_mm=0), size_only=True)
    x, y = place(page_w, page_h, bw, bh, cfg, words, anchor_box)
    return x, y, bw, bh


def _overlay_clean(page_w, page_h, info, cfg, x, y, bw, bh):
    """Plain centred CU block in the rectangle (x, y, bw, bh). Returns (page, extra length added below)."""
    lines = receipt_lines(info, cfg.get("title"))
    heights, qr = _clean_heights(bw, lines)
    extra = max(0.0, 3 * MM - y)
    c_buf = io.BytesIO()
    c = canvas.Canvas(c_buf, pagesize=(page_w, page_h + extra))

    def fit(text, font, size):
        while size > 4.5 and c.stringWidth(text, font, size) > bw - 2:
            size -= 0.25
        return size
    cx = x + bw / 2
    cur = y + bh + extra - 2 * MM
    for (kind, text), h in zip(lines, heights):
        if kind == "qr":
            w = QrCodeWidget(info["url"], barLevel="L")
            b = w.getBounds()
            d = Drawing(qr, qr, transform=[qr / (b[2] - b[0]), 0, 0, qr / (b[3] - b[1]), 0, 0])
            d.add(w)
            renderPDF.draw(d, c, cx - qr / 2, cur - qr - 2)
        else:
            size = fit(text, "Helvetica", 9.5 if kind == "h" else 7.4)
            c.setFillColor(black)
            c.setFont("Helvetica", size)
            c.drawCentredString(cx, cur - size, text)
        cur -= h
    c.save()
    return PdfReader(io.BytesIO(c_buf.getvalue())).pages[0], extra


def anchor_text_box(src, index, text, page_h):
    """Where the anchor text (e.g. 'Invoice Total') is on the page, in PDF points (origin bottom-left).
    The last occurrence on the page wins (totals are usually at the bottom)."""
    if not (text or "").strip():
        return None
    try:
        from .visual import Doc, find_all
        doc = Doc(src)
        hits = [h for h in find_all(doc, text, True) if h["page"] == index]
        if not hits:
            return None
        x0, top, x1, bottom = hits[-1]["box"]
        return (x0, page_h - bottom, x1, page_h - top)
    except Exception:
        return None


def page_words(src, index):
    """Text boxes on a page in PDF coordinates (origin bottom-left), for the Auto position."""
    try:
        import pdfplumber
        with pdfplumber.open(src) as pdf:
            pg = pdf.pages[index]
            h = float(pg.height)
            from .visual import visible
            ws = visible(pg).extract_words()
            if len(pg.chars) < 5:
                from . import ocr
                if ocr.available():
                    ws = ocr.ocr_pdf(src, [index])[index]
            boxes = [(w["x0"], h - w["bottom"], w["x1"], h - w["top"]) for w in ws]
            boxes += [(r["x0"], h - r["bottom"], r["x1"], h - r["top"]) for r in (pg.images or [])]
            return boxes
    except Exception:
        return []


def stamp_pdf(src, dst, info, cfg):
    """Write dst = src with the KRA box on the chosen page(s): first | last | all."""
    reader = PdfReader(src)
    writer = PdfWriter()
    n = len(reader.pages)
    which = (cfg.get("page") or "last").lower()
    for i, page in enumerate(reader.pages):
        if which == "all" or (which == "first" and i == 0) or (which == "last" and i == n - 1):
            box = page.mediabox
            pw, ph = float(box.width), float(box.height)
            if is_clean(cfg):
                rot = (page.get("/Rotate") or 0) % 360
                if rot:
                    page.transfer_rotation_to_content()
                    box = page.mediabox
                    pw, ph = float(box.width), float(box.height)
                anchor = (cfg.get("anchor") or "auto").lower()
                ab = anchor_text_box(src, i, cfg.get("anchor_text"), ph) if anchor == "text" else None
                x, y, bw, bh = layout(pw, ph, info, cfg, page_words(src, i), ab)
                over, extra = _overlay_clean(pw, ph, info, cfg, x, y, bw, bh)
                ox, oy = float(box.left), float(box.bottom)
                from pypdf import Transformation
                if extra:
                    # the PDF ends right under the text (till rolls): make the page longer at the bottom
                    from pypdf.generic import RectangleObject
                    grown = RectangleObject([ox, oy - extra, ox + pw, oy + ph])
                    page.mediabox = grown
                    page.cropbox = grown
                page.merge_transformed_page(over, Transformation().translate(ox, oy - extra))
                writer.add_page(page)
                continue
            anchor = (cfg.get("anchor") or "auto").lower()
            words = page_words(src, i) if anchor in ("auto", "after", "text") else None
            ab = anchor_text_box(src, i, cfg.get("anchor_text"), ph) if anchor == "text" else None
            over = _overlay(pw, ph, info, cfg, words, ab)
            # Pages with a non-zero origin or rotation: place the box in the visible area.
            rot = (page.get("/Rotate") or 0) % 360
            if rot:
                page.transfer_rotation_to_content()
                box = page.mediabox
                pw, ph = float(box.width), float(box.height)
                over = _overlay(pw, ph, info, cfg, words, ab)
            if float(box.left) or float(box.bottom):
                from pypdf import Transformation
                page.merge_transformed_page(over, Transformation().translate(float(box.left), float(box.bottom)))
            else:
                page.merge_page(over)
        writer.add_page(page)
    if reader.metadata:
        try:
            writer.add_metadata({k: str(v) for k, v in reader.metadata.items()})
        except Exception:
            pass
    writer.add_metadata({"/KRA_CU_Invoice": "%s/%s" % (info.get("sdc_id") or "", info.get("invc_no")),
                         "/KRA_Signature": info.get("rcpt_sign") or ""})
    tmp = dst + ".part"
    with open(tmp, "wb") as f:
        writer.write(f)
    import os
    os.replace(tmp, dst)
