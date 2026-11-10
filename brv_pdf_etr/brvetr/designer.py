"""Template designer: open a sample invoice, drag a box around a label, say what it is, see what is read."""
import copy
import os
import shutil
import tkinter as tk
import uuid
from tkinter import filedialog, messagebox, ttk

from datetime import datetime

from . import APP_NAME, kra, stamp, taxes, visual
from .config import data_dir
from .parser import line_incl, line_tax

NAVY, GREEN, RED, ORANGE = "#1F3A5F", "#1E8E3E", "#C5221F", "#B26A00"
TAX_CODES = ["B", "A", "C", "D", "E"]
TAX_CODES_AUTO = ["AUTO"] + TAX_CODES
GOLD = "#C38B2C"
# KRA box placement: label shown -> stamp "anchor" value
PLACES = [("Auto - first empty space", "auto"), ("Under a text (moves with it)", "text"),
          ("Fixed spot on the page", "fixed"), ("After the last line", "after"),
          ("Bottom right", "bottom-right"), ("Bottom left", "bottom-left"), ("Bottom centre", "bottom-center"),
          ("Top right", "top-right"), ("Top left", "top-left")]
PLACE_LABEL = {v: k for k, v in PLACES}
PLACE_VALUE = {k: v for k, v in PLACES}
MM = 72 / 25.4


def sample_info(sdc=""):
    return {"sdc_id": sdc or "KRACU0300000000", "invc_no": 123, "rcpt_no": 45, "tot_rcpt_no": 678,
            "intrl_data": "PREVIEWPREVIEWPREVIEWPREVI", "rcpt_sign": "PREVIEWNOTSIGNED", "credit": False,
            "when": datetime.now(), "url": "https://etims.kra.go.ke/preview"}


def guess_type(text, existing):
    t = text.lower()
    have = {r["type"] for r in existing}
    rules = [
        (("credit note no", "cn no", "credit no"), "CREDIT NOTE NO"),
        (("credit note",), "CREDIT NOTE IDENTIFIER"),
        (("original", "against inv", "ref inv"), "ORIGINAL INVOICE NO"),
        (("invoice no", "invoice. no", "inv no", "invoice #", "invoice number", "bill no", "receipt no", "folio no"), "INVOICE NO"),
        (("cust pin", "customer pin", "client pin", "buyer pin", "customer tin"), "CUSTOMER TIN"),
        (("pin",), "DOCUMENT TIN" if "DOCUMENT TIN" not in have else "CUSTOMER TIN"),
        (("catering", "levy", "tourism"), "CATERING LEVY"),
        (("service charge", "service ch"), "SERVICE CHARGE"),
        (("non vat", "non taxable", "exempt", "non-vat", "zero rated"), "NON TAXABLE"),
        (("nett", "net amount", "taxable", "sub total", "subtotal"), "NET TAXABLE"),
        (("total",), "TOTAL AMOUNT"),
        (("vat",), "VAT"),
        (("date",), "DATE"),
        (("description", "particulars", "details", "item name"), "COLUMN DESCRIPTION"),
        (("qty", "quantity"), "COLUMN QTY"),
        (("price", "rate", "unit cost"), "COLUMN PRICE"),
        (("amount", "value"), "COLUMN AMOUNT"),
        (("debit",), "COLUMN DEBIT"),
        (("credit",), "COLUMN CREDIT"),
        (("customer", "bill to", "sold to", "invoice to", "client", "guest name"), "CUSTOMER NAME"),
    ]
    for keys, typ in rules:
        if any(k in t for k in keys):
            return typ
    return "DOCUMENT IDENTIFIER"


class Designer(tk.Toplevel):
    HINT = ("Drag a box around a label on the invoice (e.g. 'INVOICE. No', 'CUST PIN', 'Invoice Total'), then check its "
            "TYPE. Blue = label found, green = value read.")
    def __init__(self, master, tpl, own_tin, on_save, tax_rules=""):
        super().__init__(master)
        self.rules = taxes.parse_rules(tax_rules)
        self.tpl = copy.deepcopy(tpl)
        self.tpl.setdefault("fields", [])
        self.own_tin = own_tin
        self.on_save = on_save
        self.doc = None
        self.page = 0
        self.zoom = 1.4
        self.img = None
        self.sel = None  # selected row index
        self.result = None
        self._after = None
        self._drag = None
        self.title("Template designer - %s" % (self.tpl.get("name") or "new client"))
        self.geometry("1240x700")
        self.minsize(900, 560)
        try:
            self.state("zoomed")
        except tk.TclError:
            pass
        self._build()
        sample = self.tpl.get("sample")
        if sample and os.path.exists(sample):
            self.load_pdf(sample)
        else:
            self.after(200, self.open_pdf)
        self.render_rows()

    # ------------------------------------------------------------------ layout
    def _build(self):
        top = ttk.Frame(self, padding=(8, 6))
        top.pack(fill="x")
        ttk.Button(top, text="Browse sample PDF...", command=self.open_pdf).pack(side="left")
        ttk.Button(top, text="◀", width=3, command=lambda: self.go(-1)).pack(side="left", padx=(10, 0))
        self.lbl_page = ttk.Label(top, text="Page -/-", width=10, anchor="center")
        self.lbl_page.pack(side="left")
        ttk.Button(top, text="▶", width=3, command=lambda: self.go(1)).pack(side="left")
        ttk.Button(top, text="−", width=3, command=lambda: self.set_zoom(self.zoom / 1.2)).pack(side="left", padx=(10, 0))
        ttk.Button(top, text="+", width=3, command=lambda: self.set_zoom(self.zoom * 1.2)).pack(side="left")
        ttk.Label(top, text="   Template name:").pack(side="left")
        self.v_name = tk.StringVar(value=self.tpl.get("name") or "")
        ttk.Entry(top, textvariable=self.v_name, width=26).pack(side="left", padx=4)
        ttk.Label(top, text="  Document:").pack(side="left")
        self.v_doc = tk.StringVar(value={"invoice": "Invoice", "credit": "Credit note"}.get(
            (self.tpl.get("doc_type") or "auto").lower(), "Detect"))
        cd = ttk.Combobox(top, textvariable=self.v_doc, values=["Invoice", "Credit note", "Detect"], width=11,
                          state="readonly")
        cd.pack(side="left", padx=4)
        cd.bind("<<ComboboxSelected>>", lambda e: self.schedule())
        ttk.Button(top, text="Item columns...", command=self.quick_columns).pack(side="left", padx=(10, 0))
        self.lbl_hint = tk.Label(self, text=self.HINT, fg=NAVY, font=("Segoe UI", 9, "bold"), anchor="w")
        self.lbl_hint.pack(fill="x", padx=10)
        sb = tk.Frame(self, bg="#FFF6E5")
        sb.pack(fill="x", padx=8, pady=(2, 2))
        st = self.tpl.setdefault("stamp", {})
        tk.Label(sb, text=" KRA box:", bg="#FFF6E5", fg=GOLD, font=("Segoe UI", 9, "bold")).pack(side="left")
        self.v_place = tk.StringVar(value=PLACE_LABEL.get(st.get("anchor") or "auto", PLACES[0][0]))
        cp = ttk.Combobox(sb, textvariable=self.v_place, values=[k for k, _ in PLACES], width=27, state="readonly")
        cp.pack(side="left", padx=3)
        cp.bind("<<ComboboxSelected>>", lambda e: self._stamp_changed())
        tk.Label(sb, text="text:", bg="#FFF6E5").pack(side="left")
        self.v_anchor = tk.StringVar(value=st.get("anchor_text") or "")
        ttk.Entry(sb, textvariable=self.v_anchor, width=16).pack(side="left", padx=2)
        self.v_anchor.trace_add("write", lambda *_: self._stamp_changed())
        ttk.Button(sb, text="Pick text", command=self.pick_anchor).pack(side="left", padx=2)
        tk.Label(sb, text=" page:", bg="#FFF6E5").pack(side="left")
        self.v_spage = tk.StringVar(value=st.get("page") or "last")
        c2 = ttk.Combobox(sb, textvariable=self.v_spage, values=["last", "first", "all"], width=5, state="readonly")
        c2.pack(side="left", padx=2)
        c2.bind("<<ComboboxSelected>>", lambda e: self._stamp_changed())
        tk.Label(sb, text=" look:", bg="#FFF6E5").pack(side="left")
        self.v_style = tk.StringVar(value="box" if st.get("style") == "box" else "clean")
        c3 = ttk.Combobox(sb, textvariable=self.v_style, values=["clean", "box"], width=6, state="readonly")
        c3.pack(side="left", padx=2)
        c3.bind("<<ComboboxSelected>>", lambda e: self._stamp_changed())
        self.btn_move = ttk.Button(sb, text="Move KRA box", command=self.toggle_move)
        self.btn_move.pack(side="left", padx=(8, 2))
        self.btn_prev = ttk.Button(sb, text="Preview real stamp", command=self.toggle_preview)
        self.btn_prev.pack(side="left", padx=2)
        self.moving = False
        self.previewing = False
        self.picking = False
        self._box = None

        pane = ttk.PanedWindow(self, orient="vertical")
        pane.pack(fill="both", expand=True, padx=8)
        # the invoice
        pv = ttk.Frame(pane)
        self.cv = tk.Canvas(pv, bg="#8A8F98", highlightthickness=0, cursor="crosshair")
        ys = ttk.Scrollbar(pv, orient="vertical", command=self.cv.yview)
        xs = ttk.Scrollbar(pv, orient="horizontal", command=self.cv.xview)
        self.cv.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        self.cv.grid(row=0, column=0, sticky="nsew")
        ys.grid(row=0, column=1, sticky="ns")
        xs.grid(row=1, column=0, sticky="ew")
        pv.rowconfigure(0, weight=1)
        pv.columnconfigure(0, weight=1)
        self.cv.bind("<ButtonPress-1>", self._press)
        self.cv.bind("<B1-Motion>", self._motion)
        self.cv.bind("<ButtonRelease-1>", self._release)
        self.cv.bind("<MouseWheel>", self._wheel)
        self.cv.bind("<Button-4>", lambda e: self.cv.yview_scroll(-3, "units"))
        self.cv.bind("<Button-5>", lambda e: self.cv.yview_scroll(3, "units"))
        pane.add(pv, weight=3)

        # the rows (like a table)
        tv = ttk.Frame(pane)
        self.tcv = tk.Canvas(tv, highlightthickness=0, height=200)
        tsb = ttk.Scrollbar(tv, orient="vertical", command=self.tcv.yview)
        self.tbl = tk.Frame(self.tcv, bg="white")
        self.tbl.bind("<Configure>", lambda e: self.tcv.configure(scrollregion=self.tcv.bbox("all")))
        self.tcv.create_window((0, 0), window=self.tbl, anchor="nw")
        self.tcv.configure(yscrollcommand=tsb.set)
        self.tcv.pack(side="left", fill="both", expand=True)
        tsb.pack(side="right", fill="y")
        pane.add(tv, weight=2)

        res = ttk.Frame(self, padding=(8, 4))
        res.pack(fill="x")
        self.lbl_res = tk.Label(res, text="", anchor="w", justify="left", font=("Segoe UI", 9, "bold"), wraplength=1000)
        self.lbl_res.pack(side="left", fill="x", expand=True)
        ttk.Button(res, text="Show lines sent to KRA", command=self.show_lines).pack(side="right")

        bot = ttk.Frame(self, padding=(8, 4, 8, 8))
        bot.pack(fill="x")
        self.v_incl = tk.BooleanVar(value=bool(self.tpl.get("prices_include_vat", True)))
        ttk.Checkbutton(bot, text="Item amounts INCLUDE VAT", variable=self.v_incl,
                        command=self.schedule).pack(side="left")
        ttk.Label(bot, text="  VAT column:").pack(side="left")
        self.v_map = tk.StringVar(value=", ".join("%s=%s" % kv for kv in (self.tpl.get("tax_map") or {}).items()))
        e = ttk.Entry(bot, textvariable=self.v_map, width=22)
        e.pack(side="left", padx=4)
        self.v_map.trace_add("write", lambda *_: self.schedule())
        ttk.Label(bot, text="  Lines with no code:").pack(side="left")
        self.v_def = tk.StringVar(value=self.tpl.get("default_tax") or "AUTO")
        cb = ttk.Combobox(bot, textvariable=self.v_def, values=TAX_CODES_AUTO, width=6, state="readonly")
        cb.pack(side="left", padx=4)
        cb.bind("<<ComboboxSelected>>", lambda e: self.schedule())
        ttk.Label(bot, text="  VAT-free =").pack(side="left")
        self.v_free = tk.StringVar(value=self.tpl.get("free_code") or "C")
        cb2 = ttk.Combobox(bot, textvariable=self.v_free, values=["C", "A"], width=4, state="readonly")
        cb2.pack(side="left", padx=4)
        cb2.bind("<<ComboboxSelected>>", lambda e: self.schedule())
        ttk.Button(bot, text="Save", style="Accent.TButton", command=self.save).pack(side="right")
        ttk.Button(bot, text="Cancel", command=self.destroy).pack(side="right", padx=6)
        ttk.Button(bot, text="+ Add row", command=lambda: self.add_row("", "DOCUMENT IDENTIFIER", None)).pack(side="right", padx=6)
        # bottom bars keep their space on small screens; the invoice and the rows share the rest
        for w in (pane, res, bot):
            w.pack_forget()
        bot.pack(side="bottom", fill="x")
        res.pack(side="bottom", fill="x")
        pane.pack(fill="both", expand=True, padx=8)

    # ------------------------------------------------------------------ PDF
    def open_pdf(self):
        path = filedialog.askopenfilename(parent=self, title="Choose a sample invoice of this client",
                                          filetypes=[("PDF", "*.pdf")])
        if path:
            self.load_pdf(path)

    def load_pdf(self, path):
        try:
            self.doc = visual.Doc(path)
            import pypdfium2
            self.pdfium = pypdfium2.PdfDocument(path)
        except Exception as e:
            messagebox.showerror(APP_NAME, "Could not open the PDF:\n%s" % e, parent=self)
            return
        if not any(p["lines"] for p in self.doc.pages):
            messagebox.showwarning(APP_NAME, "No text found in this PDF (scanned picture?). Print the invoice to PDF "
                                   "from the accounting software instead.", parent=self)
        self.sample_path = path
        self.page = 0
        self.draw_page()
        self.schedule()

    def go(self, d):
        if self.doc and 0 <= self.page + d < len(self.doc.pages):
            self.page += d
            self.draw_page()

    def set_zoom(self, z):
        self.zoom = max(0.6, min(4.0, z))
        self.draw_page()

    def _wheel(self, e):
        if e.state & 0x0004:  # Ctrl + wheel = zoom
            self.set_zoom(self.zoom * (1.1 if e.delta > 0 else 1 / 1.1))
        else:
            self.cv.yview_scroll(-1 if e.delta > 0 else 1, "units")

    def draw_page(self):
        if not self.doc:
            return
        from PIL import ImageTk
        pil = self.pdfium[self.page].render(scale=self.zoom).to_pil()
        self.img = ImageTk.PhotoImage(pil)
        self.cv.delete("all")
        self.cv.create_image(0, 0, image=self.img, anchor="nw", tags="page")
        self.cv.configure(scrollregion=(0, 0, pil.width, pil.height))
        self.lbl_page.configure(text="Page %d/%d" % (self.page + 1, len(self.doc.pages)))
        self.draw_marks()

    def _pt(self, x, y):
        return self.cv.canvasx(x) / self.zoom, self.cv.canvasy(y) / self.zoom

    def _rect(self, box, **kw):
        x0, y0, x1, y1 = [v * self.zoom for v in box]
        return self.cv.create_rectangle(x0 - 2, y0 - 1, x1 + 2, y1 + 1, tags="mark", **kw)

    def draw_marks(self):
        self.cv.delete("mark")
        if not self.result:
            return
        for pi, box in self.result.get("line_boxes", []):
            if pi == self.page:
                self._rect(box, outline="#E0B000", width=1, dash=(3, 2))
        for m in self.result["marks"]:
            if m["page"] != self.page:
                continue
            sel = m["i"] == self.sel
            if m["kbox"]:
                self._rect(m["kbox"], outline=ORANGE if sel else "#1A56DB", width=3 if sel else 2)
            if m["vbox"]:
                self._rect(m["vbox"], outline=ORANGE if sel else GREEN, width=3 if sel else 2)
        if self.sel is not None and self.sel < len(self.tpl["fields"]):
            r = self.tpl["fields"][self.sel]
            if r.get("from") == "BOX" and r.get("pos") and r.get("page", 0) == self.page:
                self._rect(r["pos"], outline=ORANGE, width=1, dash=(4, 3))
        self.draw_kra_box()

    # ------------------------------------------------------------------ KRA box position
    def _stamp_cfg(self):
        st = self.tpl.setdefault("stamp", {})
        st["anchor"] = PLACE_VALUE.get(self.v_place.get(), "auto")
        st["anchor_text"] = self.v_anchor.get().strip()
        st["page"] = self.v_spage.get() or "last"
        st["style"] = self.v_style.get() or "clean"
        return st

    def _stamp_changed(self):
        self._stamp_cfg()
        if self.previewing:
            self.toggle_preview(refresh=True)
        else:
            self.draw_marks()

    def _stamp_page(self):
        n = len(self.doc.pages)
        which = self._stamp_cfg().get("page") or "last"
        return None if which == "all" else (0 if which == "first" else n - 1)

    def kra_box(self):
        """(x0, top, x1, bottom) of the KRA box on the shown page, PDF points from the top-left; or None."""
        if not self.doc:
            return None
        sp = self._stamp_page()
        if sp is not None and sp != self.page:
            return None
        cfg = self._stamp_cfg()
        pg = self.doc.pages[self.page]
        pw, ph = pg["w"], pg["h"]
        info = sample_info()
        words = [(w["x0"], ph - w["bottom"], w["x1"], ph - w["top"]) for ln in pg["lines"] for w in ln["words"]]
        ab = None
        if cfg["anchor"] == "text" and cfg["anchor_text"]:
            hits = [h for h in visual.find_all(self.doc, cfg["anchor_text"], True) if h["page"] == self.page]
            if hits:
                x0, top, x1, bottom = hits[-1]["box"]
                ab = (x0, ph - bottom, x1, ph - top)
        x, y, bw, bh = stamp.layout(pw, ph, info, cfg, words, ab)
        return (x, ph - y - bh, x + bw, ph - y)

    def draw_kra_box(self):
        self.cv.delete("kra")
        if self.previewing:
            return
        b = self.kra_box()
        self._box = b
        if not b:
            return
        x0, y0, x1, y1 = [v * self.zoom for v in b]
        self.cv.create_rectangle(x0, y0, x1, y1, outline=GOLD, width=3 if self.moving else 2, dash=() if self.moving else (6, 3),
                                 fill="#C38B2C", stipple="gray25", tags="kra")
        self.cv.create_text((x0 + x1) / 2, (y0 + y1) / 2, text="KRA CU INFO + QR" + ("\n(drag me)" if self.moving else ""),
                            fill=NAVY, font=("Segoe UI", 9, "bold"), justify="center", tags="kra")
        covered = [w["text"] for ln in self.doc.pages[self.page]["lines"] for w in ln["words"]
                   if w["x1"] > b[0] and w["x0"] < b[2] and w["bottom"] > b[1] and w["top"] < b[3]]
        if covered:
            self.cv.create_text(x0 + 4, y0 - 8, anchor="w", fill="#B4232A", font=("Segoe UI", 9, "bold"), tags="kra",
                                text="⚠ covers text: %s" % " ".join(covered[:6]))
        cfg = self._stamp_cfg()
        if cfg["anchor"] == "text":
            hits = [h for h in visual.find_all(self.doc, cfg["anchor_text"], True) if h["page"] == self.page] \
                if cfg["anchor_text"] else []
            if hits:
                hx0, hy0, hx1, hy1 = [v * self.zoom for v in hits[-1]["box"]]
                self.cv.create_rectangle(hx0 - 2, hy0 - 2, hx1 + 2, hy1 + 2, outline=GOLD, width=2, tags="kra")

    def toggle_move(self):
        self.moving = not self.moving
        if self.previewing:
            self.toggle_preview()
        self.btn_move.configure(text="Done moving" if self.moving else "Move KRA box")
        self.lbl_hint.configure(text="Drag the gold KRA box to where it should be printed. 'Under a text' keeps it under "
                                     "that text even when the invoice is longer." if self.moving else self.HINT)
        self.draw_marks()

    def pick_anchor(self):
        self.picking = True
        self.lbl_hint.configure(text="Drag a box around the text the KRA box should follow (e.g. 'Invoice Total').")

    def toggle_preview(self, refresh=False):
        if not self.doc:
            return
        if self.previewing and not refresh:
            self.previewing = False
            self.btn_prev.configure(text="Preview real stamp")
            self.draw_page()
            return
        import tempfile
        out = os.path.join(tempfile.gettempdir(), "brv_designer_preview.pdf")
        try:
            stamp.stamp_pdf(self.sample_path, out, dict(sample_info(), currency="KES", rate=1), self._stamp_cfg())
            import pypdfium2
            from PIL import ImageTk
            d = pypdfium2.PdfDocument(out)
            pil = d[min(self.page, len(d) - 1)].render(scale=self.zoom).to_pil()
            d.close()
        except Exception as e:
            messagebox.showerror(APP_NAME, "Preview failed:\n%s" % e, parent=self)
            return
        self.previewing = True
        self.btn_prev.configure(text="Back to editing")
        self.img = ImageTk.PhotoImage(pil)
        self.cv.delete("all")
        self.cv.create_image(0, 0, image=self.img, anchor="nw", tags="page")
        self.cv.configure(scrollregion=(0, 0, pil.width, pil.height))

    # ------------------------------------------------------------------ drag a box
    def _press(self, e):
        cx, cy = self.cv.canvasx(e.x), self.cv.canvasy(e.y)
        if self.previewing:
            return
        if self.moving and self._box:
            x0, y0, x1, y1 = [v * self.zoom for v in self._box]
            if x0 <= cx <= x1 and y0 <= cy <= y1:
                self._move = (cx - x0, cy - y0, (x1 - x0), (y1 - y0))
                self._drag = None
                return
        self._move = None
        self._drag = (cx, cy)
        self.cv.delete("drag")

    def _motion(self, e):
        if getattr(self, "_move", None):
            ox, oy, w, h = self._move
            cx, cy = self.cv.canvasx(e.x) - ox, self.cv.canvasy(e.y) - oy
            self.cv.delete("kra")
            self.cv.create_rectangle(cx, cy, cx + w, cy + h, outline=GOLD, width=3, fill=GOLD, stipple="gray50", tags="kra")
            return
        if not self._drag:
            return
        self.cv.delete("drag")
        self.cv.create_rectangle(self._drag[0], self._drag[1], self.cv.canvasx(e.x), self.cv.canvasy(e.y),
                                 outline="#D93025", width=2, dash=(4, 2), tags="drag")

    def _release(self, e):
        if getattr(self, "_move", None) and self.doc:
            ox, oy, w, h = self._move
            self._move = None
            left = (self.cv.canvasx(e.x) - ox) / self.zoom
            top = (self.cv.canvasy(e.y) - oy) / self.zoom
            pg = self.doc.pages[self.page]
            left = min(max(0, left), max(0, pg["w"] - w / self.zoom))
            top = min(max(0, top), max(0, pg["h"] - h / self.zoom))
            cfg = self._stamp_cfg()
            if cfg["anchor"] == "text" and cfg["anchor_text"]:
                hits = [hh for hh in visual.find_all(self.doc, cfg["anchor_text"], True) if hh["page"] == self.page]
                if hits:
                    ax0, atop = hits[-1]["box"][0], hits[-1]["box"][1]
                    cfg["x_mm"], cfg["y_mm"] = round((left - ax0) / MM, 1), round((top - atop) / MM, 1)
                    self.lbl_res.configure(text="KRA box: %.0f mm right and %.0f mm below '%s'." % (
                        cfg["x_mm"], cfg["y_mm"], cfg["anchor_text"]), fg=GREEN)
                    self.draw_marks()
                    return
            self.v_place.set(PLACE_LABEL["fixed"])
            cfg = self._stamp_cfg()
            cfg["x_mm"], cfg["y_mm"] = round(left / MM, 1), round(top / MM, 1)
            self.lbl_res.configure(text="KRA box fixed at %.0f mm from the left, %.0f mm from the top." % (
                cfg["x_mm"], cfg["y_mm"]), fg=GREEN)
            self.draw_marks()
            return
        if not self._drag or not self.doc:
            return
        x0, y0 = self._drag[0] / self.zoom, self._drag[1] / self.zoom
        x1, y1 = self._pt(e.x, e.y)
        self._drag = None
        self.cv.delete("drag")
        x0, x1 = sorted((x0, x1))
        y0, y1 = sorted((y0, y1))
        if x1 - x0 < 3 and y1 - y0 < 3:  # a click: the word under the mouse
            for ln in self.doc.pages[self.page]["lines"]:
                for w in ln["words"]:
                    if w["x0"] - 1 <= x0 <= w["x1"] + 1 and w["top"] - 1 <= y0 <= w["bottom"] + 1:
                        x0, y0, x1, y1 = w["x0"], w["top"], w["x1"], w["bottom"]
                        break
                else:
                    continue
                break
            else:
                return
        lines = self.doc.words_in(self.page, (x0, y0, x1, y1))
        if not lines:
            return
        ws = [w for ln in lines for w in ln]
        tight = [min(w["x0"] for w in ws), min(w["top"] for w in ws), max(w["x1"] for w in ws), max(w["bottom"] for w in ws)]
        text = " ".join(" ".join(w["text"] for w in ln) for ln in lines)
        if self.picking:
            self.picking = False
            self.v_anchor.set(visual._norm(text)[:60])
            self.v_place.set(PLACE_LABEL["text"])
            st = self._stamp_cfg()
            st.setdefault("x_mm", 0)
            if not st.get("y_mm") or st.get("_new_anchor", True):
                st["x_mm"], st["y_mm"] = 0, 8
                st["_new_anchor"] = False
            self.lbl_hint.configure(text="KRA box follows '%s'. Click 'Move KRA box' to adjust it." % self.v_anchor.get())
            self.draw_marks()
            return
        # A row waiting for its box (value from BOX) takes the selection as its area.
        if self.sel is not None and self.sel < len(self.tpl["fields"]):
            r = self.tpl["fields"][self.sel]
            if r.get("from") == "BOX" and r.get("_waiting"):
                r["pos"], r["page"] = [x0, y0, x1, y1], self.page
                r.pop("_waiting", None)
                self.render_rows()
                self.schedule()
                return
        key = visual._norm(text)
        if len(lines) > 1 or len(key) > 60:
            # several lines (e.g. a name and address with no label): a fixed area
            self.add_row("", "CUSTOMER NAME", [x0, y0, x1, y1], frm="BOX")
        else:
            typ = guess_type(key, self.tpl["fields"])
            self.add_row(key.rstrip(":").strip() if typ not in ("DOCUMENT IDENTIFIER",) else key, typ, tight)

    # ------------------------------------------------------------------ rows
    def add_row(self, key, typ, pos, frm=None):
        r = visual.new_row(key, typ, pos, self.page)
        if frm:
            r["from"] = frm
        self.tpl["fields"].append(r)
        self.sel = len(self.tpl["fields"]) - 1
        self.render_rows()
        self.schedule()
        self.after(50, lambda: self.tcv.yview_moveto(1.0))

    def render_rows(self):
        for w in self.tbl.winfo_children():
            w.destroy()
        heads = [("KEY (text on the invoice)", 22), ("TYPE", 22), ("SEP.", 4), ("VALUE IS", 8), ("KRA TAX", 6),
                 ("KRA ITEM NAME", 15), ("ANY CASE", 8), ("READ FROM THIS PDF", 24), ("DEL", 3), ("TO KRA", 7)]
        for c, (h, w) in enumerate(heads):
            tk.Label(self.tbl, text=h, bg=NAVY, fg="white", font=("Segoe UI", 8, "bold"), width=w, anchor="w",
                     padx=3).grid(row=0, column=c, sticky="ew", padx=(0, 1))
        self.res_labels = []
        for i, r in enumerate(self.tpl["fields"]):
            self._row_widgets(i, r)
        self.update_results()

    def _row_widgets(self, i, r):
        g = i + 1
        bg = "#FFF4E0" if i == self.sel else "white"
        kind = visual.KIND.get(r["type"], "value")

        def bind(var, key, cast=lambda v: v):
            def changed(*_):
                r[key] = cast(var.get())
                self.schedule()
            var.trace_add("write", changed)

        v_key = tk.StringVar(value=r.get("key") or "")
        ek = ttk.Entry(self.tbl, textvariable=v_key, width=24)
        ek.grid(row=g, column=0, padx=1, pady=1, sticky="w")
        bind(v_key, "key")
        v_type = tk.StringVar(value=r["type"])
        ct = ttk.Combobox(self.tbl, textvariable=v_type, values=visual.TYPE_NAMES, width=22, state="readonly")
        ct.grid(row=g, column=1, padx=1)

        def type_changed(_e=None, r=r):
            r["type"] = v_type.get()
            d = visual.CHARGE_DEFAULTS.get(r["type"])
            if d:
                r["tax"], r["item"] = d
            self.render_rows()
            self.schedule()
        ct.bind("<<ComboboxSelected>>", type_changed)
        v_sep = tk.StringVar(value=r.get("sep") or "")
        es = ttk.Entry(self.tbl, textvariable=v_sep, width=4)
        es.grid(row=g, column=2, padx=1)
        bind(v_sep, "sep")
        v_from = tk.StringVar(value=r.get("from") or "RIGHT")
        cf = ttk.Combobox(self.tbl, textvariable=v_from, values=visual.VALUE_FROM, width=7, state="readonly")
        cf.grid(row=g, column=3, padx=1)

        def from_changed(_e=None, r=r):
            r["from"] = v_from.get()
            if r["from"] == "BOX":
                r["_waiting"] = True
                self.sel = i
                self.lbl_res.configure(text="Now drag a box on the invoice around where the value is printed.", fg=ORANGE)
            self.schedule()
        cf.bind("<<ComboboxSelected>>", from_changed)
        v_tax = tk.StringVar(value=r.get("tax") or "")
        ctax = ttk.Combobox(self.tbl, textvariable=v_tax, width=5, state="readonly",
                            values=TAX_CODES_AUTO if r["type"] in ("NET TAXABLE", "TOTAL AMOUNT") else TAX_CODES)
        ctax.grid(row=g, column=4, padx=1)
        ctax.bind("<<ComboboxSelected>>", lambda e, r=r, v=v_tax: (r.__setitem__("tax", v.get()), self.schedule()))
        v_item = tk.StringVar(value=r.get("item") or "")
        ei = ttk.Entry(self.tbl, textvariable=v_item, width=16)
        ei.grid(row=g, column=5, padx=1)
        bind(v_item, "item")
        if r["type"] not in visual.CHARGE_DEFAULTS:
            ctax.configure(state="disabled")
            ei.configure(state="disabled")
        if kind in ("key", "list", "col"):
            es.configure(state="disabled")
            cf.configure(state="disabled")
        v_case = tk.BooleanVar(value=bool(r.get("case", True)))
        ttk.Checkbutton(self.tbl, variable=v_case,
                        command=lambda r=r, v=v_case: (r.__setitem__("case", v.get()), self.schedule())
                        ).grid(row=g, column=6)
        lbl = tk.Label(self.tbl, text="", bg=bg, anchor="w", width=26, font=("Segoe UI", 9))
        lbl.grid(row=g, column=7, padx=1, sticky="w")
        self.res_labels.append(lbl)
        tk.Button(self.tbl, text="✕", fg=RED, relief="flat", bg="white", command=lambda i=i: self.delete_row(i)
                  ).grid(row=g, column=8, padx=2)
        if r["type"] in visual.NOT_SENT + ("OTHER CHARGE",):
            v_send = tk.BooleanVar(value=bool(r.get("send", r["type"] not in visual.NOT_SENT)))
            ttk.Checkbutton(self.tbl, variable=v_send,
                            command=lambda r=r, v=v_send: (r.__setitem__("send", v.get()), self.schedule())
                            ).grid(row=g, column=9)
        for w in (ek, es, ei, lbl):
            w.bind("<FocusIn>", lambda e, i=i: self.select(i), add="+")
        ct.bind("<Button-1>", lambda e, i=i: self.select(i, redraw_rows=False), add="+")
        lbl.bind("<Button-1>", lambda e, i=i: self.select(i))

    def quick_columns(self):
        """Set up the item table from a list of headings, e.g. /No,TAX,ItemDescription,:Qty,:UnitPrice,Amount"""
        if not self.doc:
            messagebox.showinfo(APP_NAME, "Open a sample PDF first.", parent=self)
            return
        from tkinter import simpledialog
        text = simpledialog.askstring(
            APP_NAME, "These headings were found on the invoice (left to right). Check them, then put : before every\n"
            "column that should NOT be used (or remove the : to use it).\n\n"
            "Example: /No,TAX,ItemDescription,:Qty,:UnitPrice,:Tax,:DiscountRt,:DiscountAmt,Amount\n"
            "= use the VAT code (TAX), description and Amount; Qty, UnitPrice, Tax, discounts not used.",
            initialvalue=visual.guess_headings(self.doc) or self.tpl.get("column_list") or
            "No,TAX,ItemDescription,Qty,UnitPrice,Amount", parent=self)
        if not text:
            return
        names = visual.parse_column_list(text)
        found = visual.find_header(self.doc, names)
        if not found:
            messagebox.showerror(APP_NAME, "None of these headings were found on the sample PDF.", parent=self)
            return
        pi, li, got = found
        line = self.doc.pages[pi]["lines"][li]
        lower = [n.lower() for n, _h in names]
        keep = [r for r in self.tpl["fields"] if visual.KIND.get(r["type"]) != "col" and r["type"] != "LIST ITEM START"]
        start = visual.new_row(line["text"], "LIST ITEM START",
                               [line["words"][0]["x0"], line["top"], line["words"][-1]["x1"], line["bottom"]], pi)
        cols = []
        types = visual.columns_from_list(names)
        for idx, (name, hint) in enumerate(names):
            hit = got.get(idx)
            if not hit:
                continue
            typ = types[idx]
            r = visual.new_row(hit["key"], typ, list(hit["box"]), pi)
            r["case"] = not (lower.count(name.lower()) > 1)  # TAX and Tax: match the exact case
            cols.append(r)
        self.tpl["fields"] = keep + [start] + cols
        self.tpl["column_list"] = text
        missing = [n for i, (n, _h) in enumerate(names) if i not in got]
        self.sel = None
        self.render_rows()
        self.schedule()
        used = [c for c in cols if c["type"] != "COLUMN IGNORE"]
        msg = "Used: %s.\nNot used: %s." % (
            ", ".join("%s = %s" % (c["key"], c["type"].replace("COLUMN ", "")) for c in used) or "-",
            ", ".join(c["key"] for c in cols if c["type"] == "COLUMN IGNORE") or "-")
        if missing:
            msg += "\nNot found on this PDF: %s" % ", ".join(missing)
        if not any(r["type"] == "LIST ITEM END" for r in self.tpl["fields"]):
            msg += "\n\nThe item list stops at the first Total / Sub total line (add a LIST ITEM END row to change)."
        messagebox.showinfo(APP_NAME, msg, parent=self)

    def select(self, i, redraw_rows=False):
        if self.sel == i:
            return
        self.sel = i
        if i < len(self.tpl["fields"]):
            r = self.tpl["fields"][i]
            self.lbl_hint.configure(text="%s: %s" % (r["type"], visual.HELP.get(r["type"], "")))
        for j, lbl in enumerate(self.res_labels):
            lbl.configure(bg="#FFF4E0" if j == i else "white")
        self.draw_marks()
        if self.result:
            m = self.result["marks"][i] if i < len(self.result["marks"]) else None
            if m and m["page"] is not None and m["page"] != self.page:
                self.page = m["page"]
                self.draw_page()

    def delete_row(self, i):
        del self.tpl["fields"][i]
        self.sel = None
        self.render_rows()
        self.schedule()

    # ------------------------------------------------------------------ what is read
    def _tpl_now(self):
        t = self.tpl
        t["name"] = self.v_name.get().strip() or "New client"
        t["prices_include_vat"] = bool(self.v_incl.get())
        t["default_tax"] = self.v_def.get() or "AUTO"
        t["doc_type"] = {"Invoice": "invoice", "Credit note": "credit"}.get(self.v_doc.get(), "auto")
        t["free_code"] = self.v_free.get() or "C"
        mp = {}
        for part in self.v_map.get().split(","):
            if "=" in part:
                a, b = part.split("=", 1)
                if a.strip() and b.strip():
                    mp[a.strip()] = b.strip().upper()
        t["tax_map"] = mp
        return t

    def schedule(self):
        if self._after:
            self.after_cancel(self._after)
        self._after = self.after(250, self.update_results)

    def update_results(self):
        self._after = None
        if not self.doc:
            self.lbl_res.configure(text="Open a sample PDF of this client.", fg=ORANGE)
            return
        t = self._tpl_now()
        try:
            self.result = visual.read(self.doc, t, self.own_tin)
        except Exception as e:
            self.lbl_res.configure(text="Problem: %s" % e, fg=RED)
            return
        for m, lbl in zip(self.result["marks"], self.res_labels):
            r = t["fields"][m["i"]]
            if r.get("_waiting"):
                lbl.configure(text="drag a box on the invoice...", fg=ORANGE)
            elif m["found"]:
                lbl.configure(text=m["text"] or "found", fg=GREEN)
            else:
                lbl.configure(text="not found", fg=RED)
        self.draw_marks()
        self.lbl_res.configure(**self._summary(t))

    def _sale(self, t):
        self.tax_problems, self.tax_notes = taxes.resolve(self.result, t, self.rules)
        out = []
        for ln in self.result["lines"]:
            code = line_tax(t, ln)
            rate = kra.TAX_RATES.get(code, 0)
            incl = ln["amount"] if line_incl(t, ln) else ln["amount"] * (100 + rate) / 100
            out.append((ln, code, kra.r2(incl)))
        return out

    def _summary(self, t):
        p = self.result
        miss = []
        if not p["invoice_no"]:
            miss.append("INVOICE NO")
        if not any(r["type"] == "DOCUMENT IDENTIFIER" and r.get("key") for r in t["fields"]):
            miss.append("a DOCUMENT IDENTIFIER (text only this client's invoices have)")
        sale = self._sale(t)
        total = kra.r2(sum(x for _, _, x in sale))
        left_out = kra.r2(sum(a for _, a in p.get("excluded") or []))
        parts = ["Invoice %s" % (p["invoice_no"] or "?"),
                 "Customer: %s" % (p["customer_name"] or "-"),
                 "PIN: %s" % (p["customer_pin"] or "none")]
        if p["credit_note"]:
            parts.append("CREDIT NOTE of %s" % (p["original_invoice"] or "?"))
        how = ("%d item line(s)" % len(p["items"]) if p["mode"] == "items" else "signed from the totals: " + " + ".join(
            "%s %s (%s)" % (ln["desc"], "{:,.2f}".format(x), c) for ln, c, x in sale))
        parts.append(how)
        if p.get("excluded"):
            parts.append("NOT sent to KRA: " + ", ".join("%s %s" % (n, "{:,.2f}".format(a)) for n, a in p["excluded"]))
        txt = "   |   ".join(parts)
        if p["total"] is None:
            txt += "\n✘ Add the TOTAL AMOUNT row so the app can check everything adds up."
            fg = ORANGE
        elif not sale:
            txt += "\n✘ Nothing to sign yet: add item columns (LIST ITEM START + COLUMN rows) or NET TAXABLE / VAT / TOTAL AMOUNT."
            fg = RED
        elif self.tax_problems:
            txt += "\n✘ " + self.tax_problems[0]
            fg = RED
        elif abs(abs(p["total"]) - left_out - total) <= max(1.0, abs(p["total"]) * 0.001):
            txt += "\n✔ To KRA {:,.2f}{} = invoice total {:,.2f}.".format(
                total, " + not sent {:,.2f}".format(left_out) if left_out else "", abs(p["total"]))
            if p.get("vat") is not None:
                txt += "  VAT {:,.2f} ✔".format(p.get("vat_calc") or 0)
            fg = GREEN
        else:
            txt += "\n✘ To KRA {:,.2f}{} but the invoice total is {:,.2f}.".format(
                total, " + not sent {:,.2f}".format(left_out) if left_out else "", p["total"])
            fg = RED
        if miss:
            txt += "   Still needed: " + ", ".join(miss) + "."
            fg = RED if fg == GREEN else fg
        notes = p["notes"] + self.tax_notes
        if notes:
            txt += "   Note: " + " ".join(notes[:2])
        return {"text": txt, "fg": fg}

    def show_lines(self):
        if not self.result:
            return
        t = self._tpl_now()
        w = tk.Toplevel(self)
        w.title("Lines sent to KRA")
        w.geometry("820x380")
        cols = ("desc", "qty", "amount", "code", "incl")
        tree = ttk.Treeview(w, columns=cols, show="headings")
        for c, h, wd in zip(cols, ("Description", "Qty", "Amount on PDF", "KRA tax", "Total incl. VAT"),
                            (380, 60, 110, 80, 120)):
            tree.heading(c, text=h)
            tree.column(c, width=wd, anchor="w" if c == "desc" else "e")
        for ln, code, incl in self._sale(t):
            tree.insert("", "end", values=(ln["desc"], "%g" % ln["qty"], "{:,.2f}".format(ln["amount"]),
                                           kra.TAX_NAMES.get(code, code), "{:,.2f}".format(incl)))
        tree.pack(fill="both", expand=True, padx=8, pady=8)

    # ------------------------------------------------------------------ save
    def save(self):
        t = self._tpl_now()
        st = self._stamp_cfg()
        st.pop("_new_anchor", None)
        if st["anchor"] == "text" and not st["anchor_text"]:
            messagebox.showwarning(APP_NAME, "Choose the text the KRA box should follow (Pick text), or another "
                                   "position.", parent=self)
            return
        if not any(r["type"] == "DOCUMENT IDENTIFIER" and r.get("key") for r in t["fields"]):
            if not messagebox.askyesno(APP_NAME, "There is no DOCUMENT IDENTIFIER row, so this template will be used "
                                       "for any PDF that no other template recognises.\n\nSave anyway?", parent=self):
                return
        for r in t["fields"]:
            r.pop("_waiting", None)
        if getattr(self, "sample_path", None) and self.sample_path != t.get("sample"):
            try:
                d = os.path.join(data_dir(), "samples")
                os.makedirs(d, exist_ok=True)
                dst = os.path.join(d, "%s.pdf" % uuid.uuid4().hex[:12])
                shutil.copy(self.sample_path, dst)
                t["sample"] = dst
            except OSError:
                t["sample"] = self.sample_path
        self.on_save(t)
        self.destroy()
