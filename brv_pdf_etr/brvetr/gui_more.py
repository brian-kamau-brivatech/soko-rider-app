"""Items, Reports, Licence and admin lock screens of the main window."""
import calendar
import os
import threading
import tkinter as tk
from datetime import date, datetime, timedelta
from tkinter import filedialog, messagebox, simpledialog, ttk

from . import APP_NAME, VERSION, licence, reports, secure
from . import items as itemreg

NAVY, NAVY2, GOLD, BG = "#0A2348", "#1B3F73", "#C38B2C", "#F4F6FA"
GREEN, RED, ORANGE, MUTED = "#0E8A55", "#B4232A", "#A95C00", "#5B6576"
ADMIN_MINUTES = 15


def logo_image(name, height):
    try:
        from PIL import Image, ImageTk
        im = Image.open(reports.asset(name)).convert("RGBA")
        w = int(im.width * height / im.height)
        return ImageTk.PhotoImage(im.resize((w, height), Image.LANCZOS))
    except Exception:
        import traceback
        traceback.print_exc()
        return None


class Dialog(tk.Toplevel):
    def __init__(self, master, title, width=520, height=360):
        super().__init__(master)
        self.title(title)
        self.configure(bg=BG)
        self.geometry("%dx%d" % (width, height))
        self.transient(master)
        self.resizable(False, False)
        self.result = None

    def modal(self):
        self.grab_set()
        self.wait_window()
        return self.result


class MoreScreens:
    # ------------------------------------------------------------------ admin lock
    def admin_setup_if_needed(self):
        if self.s.get("admin_pw"):
            return
        messagebox.showinfo(APP_NAME, "First start: create the ADMIN password.\n\nOnly BRV / the person who sets up the "
                                      "app should know it. It protects Settings, Client templates and Items.",
                            parent=self.root)
        while True:
            pw = simpledialog.askstring(APP_NAME, "New admin password (at least 4 characters):", show="*", parent=self.root)
            if pw is None:
                return
            if len(pw) < 4:
                continue
            again = simpledialog.askstring(APP_NAME, "Type the admin password again:", show="*", parent=self.root)
            if again == pw:
                self.s["admin_pw"] = secure.hash_password(pw)
                self.s.save()
                self.unlock(silent=True)
                return
            messagebox.showwarning(APP_NAME, "The two passwords are not the same.", parent=self.root)

    def admin_click(self):
        if self.admin:
            self.lock()
            return
        if not self.s.get("admin_pw"):
            self.admin_setup_if_needed()
            return
        pw = simpledialog.askstring(APP_NAME, "Admin password:", show="*", parent=self.root)
        if pw is None:
            return
        if secure.check_password(pw, self.s.get("admin_pw")):
            self.unlock()
        else:
            messagebox.showerror(APP_NAME, "Wrong password.", parent=self.root)

    def unlock(self, silent=False):
        self.admin = True
        for tab, text in self.admin_tabs:
            self.nb.add(tab, text=text)
        self.btn_admin.configure(text="Lock admin")
        self._admin_until = datetime.now() + timedelta(minutes=ADMIN_MINUTES)
        if not silent:
            self.log("Admin unlocked (locks again after %d minutes)." % ADMIN_MINUTES, "info")

    def lock(self):
        self.admin = False
        for tab, _t in self.admin_tabs:
            try:
                self.nb.hide(tab)
            except tk.TclError:
                pass
        self.nb.select(self.tab_inv)
        self.btn_admin.configure(text="Admin")

    def admin_tick(self):
        if self.admin and datetime.now() > self._admin_until:
            self.lock()
            self.log("Admin locked automatically.", "info")

    def admin_touch(self, _e=None):
        if self.admin:
            self._admin_until = datetime.now() + timedelta(minutes=ADMIN_MINUTES)

    def change_password(self):
        pw = simpledialog.askstring(APP_NAME, "New admin password (at least 4 characters):", show="*", parent=self.root)
        if not pw or len(pw) < 4:
            return
        if simpledialog.askstring(APP_NAME, "Type it again:", show="*", parent=self.root) != pw:
            messagebox.showwarning(APP_NAME, "The two passwords are not the same.", parent=self.root)
            return
        self.s["admin_pw"] = secure.hash_password(pw)
        self.s.save()
        self.log("Admin password changed.", "info")

    # ------------------------------------------------------------------ licence
    def licence_banner(self):
        st = licence.status(self.s)
        if st["state"] == "ok":
            self.lbl_lic.configure(text="✔ " + st["message"], bg=BG, fg=GREEN)
        elif st["state"] == "warn":
            self.lbl_lic.configure(text="⚠ " + st["message"] + "  Contact BRV to renew.", bg="#FFF3DF", fg=ORANGE)
        else:
            self.lbl_lic.configure(text="✖ NOT SIGNING: " + st["message"], bg="#FDECEC", fg=RED)
        return st

    def licence_dialog(self):
        d = Dialog(self.root, "Licence - %s" % APP_NAME, 640, 470)
        img = logo_image("brv_logo.png", 110)
        if img:
            tk.Label(d, image=img, bg=BG).pack(pady=(14, 4))
            d._img = img
        st = licence.status(self.s)
        tk.Label(d, text=st["message"], bg=BG, font=("Segoe UI", 10, "bold"),
                 fg=GREEN if st["ok"] else RED, wraplength=580).pack(pady=4)
        box = tk.Frame(d, bg=BG)
        box.pack(pady=6)
        tk.Label(box, text="Machine code of this computer:", bg=BG, font=("Segoe UI", 10)).pack(side="left")
        code = secure.machine_code()
        e = tk.Entry(box, font=("Consolas", 14, "bold"), width=11, justify="center", fg=NAVY)
        e.insert(0, code)
        e.configure(state="readonly")
        e.pack(side="left", padx=6)

        def copy():
            self.root.clipboard_clear()
            self.root.clipboard_append(code)
        ttk.Button(box, text="Copy", command=copy).pack(side="left")
        tk.Label(d, text="Send this machine code to BRV. Paste the licence key you receive below:", bg=BG,
                 fg=MUTED).pack(pady=(8, 2))
        t = tk.Text(d, height=4, width=70, font=("Consolas", 9), wrap="char")
        t.pack(padx=20)
        if self.s.get("licence"):
            t.insert("1.0", self.s["licence"])

        def activate():
            key = " ".join(t.get("1.0", "end").split())
            info, err = licence.read(key)
            if not info:
                messagebox.showerror(APP_NAME, err, parent=d)
                return
            if info["machine"] != code:
                messagebox.showerror(APP_NAME, "This key is for computer %s, not this one (%s)." % (info["machine"], code),
                                     parent=d)
                return
            self.s["licence"] = key
            self.s.save()
            st2 = self.licence_banner()
            messagebox.showinfo(APP_NAME, st2["message"], parent=d)
            self.log("Licence entered: %s" % st2["message"], "info")
            d.destroy()
            if st2["ok"]:
                self._bg(self.engine.scan_once)
        bar = tk.Frame(d, bg=BG)
        bar.pack(pady=10)
        ttk.Button(bar, text="Activate licence", style="Accent.TButton", command=activate).pack(side="left", padx=4)
        ttk.Button(bar, text="Close", command=d.destroy).pack(side="left", padx=4)
        tk.Label(d, text=licence.CONTACT, bg=BG, fg=MUTED, font=("Segoe UI", 8)).pack(side="bottom", pady=6)

    def about(self):
        d = Dialog(self.root, "About", 520, 360)
        img = logo_image("brv_logo.png", 150)
        if img:
            tk.Label(d, image=img, bg=BG).pack(pady=(16, 6))
            d._img = img
        tk.Label(d, text="%s %s" % (APP_NAME, VERSION), bg=BG, fg=NAVY, font=("Segoe UI", 13, "bold")).pack()
        tk.Label(d, text="KRA eTIMS signing of invoice PDFs through a VSCU", bg=BG, fg=MUTED).pack()
        tk.Label(d, text=licence.CONTACT, bg=BG, fg=GOLD, font=("Segoe UI", 9, "bold")).pack(pady=8)
        ttk.Button(d, text="Close", command=d.destroy).pack(pady=6)

    # ------------------------------------------------------------------ items tab
    def _items_tab(self):
        f = self.tab_items
        top = ttk.Frame(f)
        top.pack(fill="x")
        ttk.Label(top, text="Search:").pack(side="left")
        self.iq = tk.StringVar()
        e = ttk.Entry(top, textvariable=self.iq, width=18)
        e.pack(side="left", padx=6)
        e.bind("<KeyRelease>", lambda _e: self.items_refresh())
        for text, cmd, style in (("Add", self.item_add, "Accent.TButton"), ("Edit", self.item_edit, None),
                                 ("Delete", self.item_delete, None)):
            ttk.Button(top, text=text, command=cmd, style=style or "TButton").pack(side="left", padx=2)
        ttk.Separator(top, orient="vertical").pack(side="left", fill="y", padx=8)
        ttk.Button(top, text="Register at KRA", style="Gold.TButton", command=self.items_register).pack(side="right", padx=2)
        ttk.Button(top, text="Excel template", command=self.items_template).pack(side="left", padx=2)
        ttk.Button(top, text="Import Excel", command=self.items_import).pack(side="left", padx=2)
        ttk.Button(top, text="Export Excel", command=self.items_export).pack(side="left", padx=2)
        cols = ("sku", "name", "tax", "cls", "unit", "type", "price", "kra", "reg", "src")
        heads = ("Item code", "Item name", "Tax group", "KRA class", "Units", "Type", "Price", "KRA item code",
                 "At KRA", "Added by")
        widths = (90, 260, 120, 90, 70, 50, 80, 170, 130, 70)
        fr = ttk.Frame(f)
        fr.pack(fill="both", expand=True, pady=6)
        self.itree = ttk.Treeview(fr, columns=cols, show="headings", selectmode="extended")
        for c, h, w in zip(cols, heads, widths):
            self.itree.heading(c, text=h)
            self.itree.column(c, width=w, anchor="e" if c == "price" else "w", stretch=c == "name")
        sb = ttk.Scrollbar(fr, orient="vertical", command=self.itree.yview)
        self.itree.configure(yscrollcommand=sb.set)
        self.itree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.itree.tag_configure("no", foreground=ORANGE)
        self.itree.tag_configure("err", foreground=RED)
        self.itree.bind("<Double-1>", lambda _e: self.item_edit())
        self.lbl_items = tk.Label(f, text="", anchor="w", fg=MUTED, bg=BG)
        self.lbl_items.pack(fill="x")
        tk.Label(f, text="The tax group of an item is used whenever an invoice line does not print its own VAT code. "
                         "Items are found by item code (if the template reads a code column) or by name.",
                 anchor="w", fg=MUTED, bg=BG, wraplength=1000, justify="left").pack(fill="x")
        self.items_refresh()

    def items_refresh(self):
        self.itree.delete(*self.itree.get_children())
        rows = self.engine.db.items(self.iq.get().strip() if hasattr(self, "iq") else "")
        pending = 0
        for r in rows:
            reg = "Yes" if r["registered"] else ("Error: " + r["reg_error"] if r["reg_error"] else "Not yet")
            pending += 0 if r["registered"] else 1
            self.itree.insert("", "end", iid=str(r["id"]),
                              tags=("" if r["registered"] else ("err" if r["reg_error"] else "no"),),
                              values=(r["sku"] or "", r["name"], itemreg.TAX_GROUPS.get(r["tax"], r["tax"]),
                                      r["cls_cd"] or "", "%s / %s" % (r["qty_unit"], r["pkg_unit"]), r["item_type"],
                                      "{:,.2f}".format(r["price"] or 0), r["item_cd"], reg, r["source"] or ""))
        self.lbl_items.configure(text="%d item(s), %d not yet registered at KRA" % (len(rows), pending))

    def _item_form(self, row=None):
        d = Dialog(self.root, "Edit item" if row else "Add item", 560, 420)
        vals = {}
        fields = [("sku", "Item code (optional)", None), ("name", "Item name *", None),
                  ("tax", "Tax group *", list(itemreg.TAX_GROUPS.values())),
                  ("cls_cd", "KRA item class code", None), ("qty_unit", "Quantity unit", itemreg.QTY_UNITS),
                  ("pkg_unit", "Packaging unit", itemreg.PKG_UNITS), ("item_type", "Item type", list(itemreg.ITEM_TYPES.values())),
                  ("price", "Unit price incl. VAT", None), ("origin", "Country of origin", None)]
        frm = tk.Frame(d, bg=BG)
        frm.pack(padx=18, pady=14, fill="x")
        for i, (k, label, choices) in enumerate(fields):
            tk.Label(frm, text=label, bg=BG, anchor="w").grid(row=i, column=0, sticky="w", pady=4)
            v = tk.StringVar()
            if row is not None:
                cur = row[k]
                if k == "tax":
                    cur = itemreg.TAX_GROUPS.get(cur, cur)
                if k == "item_type":
                    cur = itemreg.ITEM_TYPES.get(cur, cur)
                v.set("" if cur is None else str(cur))
            else:
                v.set({"tax": itemreg.TAX_GROUPS["B"], "qty_unit": "U", "pkg_unit": "NT",
                       "item_type": itemreg.ITEM_TYPES["2"], "origin": "KE",
                       "cls_cd": self.s.get("item_class") or ""}.get(k, ""))
            w = ttk.Combobox(frm, textvariable=v, values=choices, width=34,
                             state="readonly" if k in ("tax", "item_type") else "normal") if choices else \
                ttk.Entry(frm, textvariable=v, width=37)
            w.grid(row=i, column=1, sticky="w", padx=8)
            vals[k] = v
        reg = tk.BooleanVar(value=self.s.ready)
        ttk.Checkbutton(d, text="Register at KRA now", variable=reg).pack(anchor="w", padx=18)

        def save():
            raw = {k: v.get() for k, v in vals.items()}
            raw["tax"] = raw["tax"][:1]
            raw["item_type"] = raw["item_type"][:1]
            it, errs = itemreg.clean(raw, self.s.get("item_class") or "")
            if errs:
                messagebox.showerror(APP_NAME, "\n".join(errs), parent=d)
                return
            other = self.engine.db.item(it["name"])
            if other and (row is None or other["id"] != row["id"]):
                messagebox.showerror(APP_NAME, "An item named '%s' already exists." % it["name"], parent=d)
                return
            if row is not None:
                self.engine.db.update("items", row["id"], {"sku": it["sku"]})
            iid, changed = itemreg.upsert(self.engine.db, it, "manual")
            d.result = (iid, changed and reg.get())
            d.destroy()
        bar = tk.Frame(d, bg=BG)
        bar.pack(pady=10)
        ttk.Button(bar, text="Save", style="Accent.TButton", command=save).pack(side="left", padx=4)
        ttk.Button(bar, text="Cancel", command=d.destroy).pack(side="left", padx=4)
        return d.modal()

    def item_add(self):
        res = self._item_form()
        if res:
            self.items_refresh()
            if res[1]:
                self._register_ids([res[0]])

    def item_edit(self):
        sel = self.itree.selection()
        if not sel:
            return
        row = self.engine.db.item_by_id(int(sel[0]))
        res = self._item_form(row)
        if res:
            self.items_refresh()
            if res[1]:
                self._register_ids([res[0]])

    def item_delete(self):
        sel = self.itree.selection()
        if not sel or not messagebox.askyesno(APP_NAME, "Delete %d item(s) from this list?\n\n(KRA keeps items already "
                                              "registered; they are only removed here.)" % len(sel)):
            return
        for i in sel:
            self.engine.db.delete_item(int(i))
        self.items_refresh()

    def items_template(self):
        p = filedialog.asksaveasfilename(title="Save the Excel template", defaultextension=".xlsx",
                                         initialfile="BRV-PDF-ETR-items.xlsx", filetypes=[("Excel", "*.xlsx")])
        if p:
            itemreg.write_template(p)
            self._open_file(p)

    def items_export(self):
        p = filedialog.asksaveasfilename(title="Export items", defaultextension=".xlsx",
                                         initialfile="Items %s.xlsx" % date.today().isoformat(), filetypes=[("Excel", "*.xlsx")])
        if p:
            itemreg.export(p, self.engine.db.items())
            self._open_file(p)

    def items_import(self):
        p = filedialog.askopenfilename(title="Choose the Excel item list", filetypes=[("Excel or CSV", "*.xlsx *.csv")])
        if not p:
            return
        try:
            rows, errors = itemreg.read_file(p, self.s.get("item_class") or "")
        except Exception as e:
            messagebox.showerror(APP_NAME, "Cannot read the file:\n%s" % e)
            return
        if errors and not rows:
            messagebox.showerror(APP_NAME, "Nothing imported:\n\n" + "\n".join(errors[:20]))
            return
        msg = "%d item(s) ready to import." % len(rows)
        if errors:
            msg += "\n\n%d row(s) have problems and will be skipped:\n%s" % (len(errors), "\n".join(errors[:15]))
        if not messagebox.askyesno(APP_NAME, msg + "\n\nImport now?"):
            return
        ids = []
        for it in rows:
            iid, changed = itemreg.upsert(self.engine.db, it, "import")
            if changed:
                ids.append(iid)
        self.items_refresh()
        self.log("Imported %d item(s) from %s." % (len(rows), os.path.basename(p)), "info")
        if ids and self.s.ready and messagebox.askyesno(APP_NAME, "Register the %d new/changed item(s) at KRA now?" % len(ids)):
            self._register_ids(ids)

    def items_register(self):
        sel = [int(i) for i in self.itree.selection()]
        if not sel:
            sel = [r["id"] for r in self.engine.db.items() if not r["registered"]]
        if not sel:
            messagebox.showinfo(APP_NAME, "All items are registered at KRA.")
            return
        self._register_ids(sel)

    def _register_ids(self, ids):
        if not self.s.ready:
            messagebox.showwarning(APP_NAME, "Connect to the VSCU first (Settings).")
            return

        def work():
            ok = bad = 0
            for i in ids:
                res = self.engine.register_item(i)
                if res.ok:
                    ok += 1
                else:
                    bad += 1
                    if res.no_answer:
                        self.events.put(("error", "VSCU not answering; item registration stopped."))
                        break
            self.events.put(("info" if not bad else "error", "Items registered at KRA: %d ok, %d not." % (ok, bad)))
            self.root.after(0, self.items_refresh)
        self._bg(work)

    # ------------------------------------------------------------------ reports tab
    def _reports_tab(self):
        f = self.tab_rep
        top = ttk.Frame(f)
        top.pack(fill="x")
        today = date.today()
        self.r_from = tk.StringVar(value=today.replace(day=1).isoformat())
        self.r_to = tk.StringVar(value=today.isoformat())
        ttk.Label(top, text="From").pack(side="left")
        ttk.Entry(top, textvariable=self.r_from, width=11).pack(side="left", padx=4)
        ttk.Label(top, text="To").pack(side="left")
        ttk.Entry(top, textvariable=self.r_to, width=11).pack(side="left", padx=4)
        for text, fn in (("Today", self._p_today), ("This week", self._p_week), ("This month", self._p_month),
                         ("Last month", self._p_last_month)):
            ttk.Button(top, text=text, command=fn).pack(side="left", padx=1)
        ttk.Label(top, text="   Show").pack(side="left")
        self.r_kind = tk.StringVar(value="ALL")
        c = ttk.Combobox(top, textvariable=self.r_kind, values=["ALL", "INVOICES", "CREDIT NOTES"], width=13, state="readonly")
        c.pack(side="left", padx=4)
        c.bind("<<ComboboxSelected>>", lambda e: self.report_refresh())
        self.r_cur = tk.StringVar(value="ALL")
        c2 = ttk.Combobox(top, textvariable=self.r_cur, values=["ALL", "KES", "USD", "EUR", "GBP"], width=6, state="readonly")
        c2.pack(side="left", padx=4)
        c2.bind("<<ComboboxSelected>>", lambda e: self.report_refresh())
        ttk.Button(top, text="Show", style="Accent.TButton", command=self.report_refresh).pack(side="left", padx=6)
        exp = ttk.Frame(f)
        exp.pack(fill="x", pady=(6, 0))
        self.lbl_rep = tk.Label(exp, text="", bg=BG, fg=NAVY, font=("Segoe UI", 10, "bold"), anchor="w", justify="left")
        self.lbl_rep.pack(side="left", fill="x", expand=True)
        ttk.Button(exp, text="Export PDF...", command=lambda: self.report_export("pdf")).pack(side="right", padx=2)
        ttk.Button(exp, text="Export CSV...", command=lambda: self.report_export("csv")).pack(side="right", padx=2)
        ttk.Button(exp, text="Export Excel...", style="Accent.TButton",
                   command=lambda: self.report_export("xlsx")).pack(side="right", padx=2)
        mid = ttk.Frame(f)
        mid.pack(fill="x", pady=6)
        self.tax_tree = ttk.Treeview(mid, columns=("g", "t", "v", "s"), show="headings", height=6)
        for c_, h, w in (("g", "Tax group", 140), ("t", "Taxable KES", 120), ("v", "VAT KES", 110), ("s", "Total KES", 120)):
            self.tax_tree.heading(c_, text=h)
            self.tax_tree.column(c_, width=w, anchor="w" if c_ == "g" else "e")
        self.tax_tree.pack(side="left")
        self.cur_tree = ttk.Treeview(mid, columns=("c", "n", "a", "k"), show="headings", height=6)
        for c_, h, w in (("c", "Currency", 80), ("n", "Docs", 60), ("a", "Amount", 120), ("k", "To KRA KES", 120)):
            self.cur_tree.heading(c_, text=h)
            self.cur_tree.column(c_, width=w, anchor="w" if c_ == "c" else "e")
        self.cur_tree.pack(side="left", padx=12)
        cols = ("date", "type", "inv", "kra", "cust", "pin", "cur", "amt", "taxbl", "vat", "tot", "cu")
        heads = ("Date", "Type", "Invoice", "KRA no.", "Customer", "PIN", "Cur.", "Amount", "Taxable KES", "VAT KES",
                 "Total KES", "CU invoice no.")
        widths = (85, 85, 90, 60, 190, 100, 45, 95, 100, 90, 100, 170)
        fr = ttk.Frame(f)
        fr.pack(fill="both", expand=True)
        self.rtree = ttk.Treeview(fr, columns=cols, show="headings")
        for c_, h, w in zip(cols, heads, widths):
            self.rtree.heading(c_, text=h)
            self.rtree.column(c_, width=w, anchor="e" if c_ in ("amt", "taxbl", "vat", "tot", "kra") else "w",
                              stretch=c_ == "cust")
        sb = ttk.Scrollbar(fr, orient="vertical", command=self.rtree.yview)
        self.rtree.configure(yscrollcommand=sb.set)
        self.rtree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.rtree.tag_configure("cn", foreground=RED)
        self.report_refresh()

    def _p_today(self):
        self.r_from.set(date.today().isoformat())
        self.r_to.set(date.today().isoformat())
        self.report_refresh()

    def _p_week(self):
        t = date.today()
        self.r_from.set((t - timedelta(days=t.weekday())).isoformat())
        self.r_to.set(t.isoformat())
        self.report_refresh()

    def _p_month(self):
        t = date.today()
        self.r_from.set(t.replace(day=1).isoformat())
        self.r_to.set(t.isoformat())
        self.report_refresh()

    def _p_last_month(self):
        t = date.today().replace(day=1) - timedelta(days=1)
        self.r_from.set(t.replace(day=1).isoformat())
        self.r_to.set(t.replace(day=calendar.monthrange(t.year, t.month)[1]).isoformat())
        self.report_refresh()

    def _period(self):
        try:
            a = date.fromisoformat(self.r_from.get().strip())
            b = date.fromisoformat(self.r_to.get().strip())
        except ValueError:
            messagebox.showwarning(APP_NAME, "Dates must look like 2026-10-31.")
            return None
        return (a, b) if a <= b else (b, a)

    def report_refresh(self):
        per = self._period()
        if not per:
            return
        self.rep_data = reports.rows(self.engine.db, per[0].isoformat(), per[1].isoformat(), self.r_kind.get(),
                                     self.r_cur.get())
        s = reports.summary(self.rep_data)
        fm = lambda v: "{:,.2f}".format(v)
        self.lbl_rep.configure(text="%d invoice(s)  %s   |   %d credit note(s)  %s   |   Net to KRA %s   VAT %s%s" % (
            s["count_inv"], fm(s["inv_total"]), s["count_cn"], fm(s["cn_total"]), fm(s["total"]), fm(s["vat"]),
            ("   |   Levy/service not sent %s" % fm(s["excluded"])) if s["excluded"] else ""))
        self.tax_tree.delete(*self.tax_tree.get_children())
        for t, n in reports.TAX_ROWS:
            self.tax_tree.insert("", "end", values=(n, fm(s["taxbl_" + t]), fm(s["vat_" + t]),
                                                    fm(s["taxbl_" + t] + s["vat_" + t])))
        self.tax_tree.insert("", "end", values=("TOTAL", fm(s["taxable"]), fm(s["vat"]), fm(s["total"])))
        self.cur_tree.delete(*self.cur_tree.get_children())
        for c in s["currencies"]:
            self.cur_tree.insert("", "end", values=(c["currency"], c["count"], fm(c["amount_fc"]), fm(c["total"])))
        self.rtree.delete(*self.rtree.get_children())
        for d in self.rep_data:
            self.rtree.insert("", "end", tags=("cn",) if d["type"] == "Credit note" else (), values=(
                d["date"], d["type"], d["invoice"], d["kra_no"], d["customer"], d["pin"], d["currency"],
                fm(d["amount_fc"]), fm(d["taxable"]), fm(d["vat"]), fm(d["total"]), d["cu"]))

    def report_export(self, kind):
        per = self._period()
        if not per:
            return
        self.report_refresh()
        name = "Sales report %s to %s" % (per[0].isoformat(), per[1].isoformat())
        p = filedialog.asksaveasfilename(title="Save report", defaultextension="." + kind, initialfile=name + "." + kind,
                                         filetypes=[{"xlsx": ("Excel", "*.xlsx"), "pdf": ("PDF", "*.pdf"),
                                                     "csv": ("CSV", "*.csv")}[kind]])
        if not p:
            return
        business = "%s  |  PIN %s" % (self.s.get("taxpayer_name") or "", self.s.get("tin") or "")
        filters = "%s, %s" % ({"ALL": "All documents", "INVOICES": "Invoices only", "CREDIT NOTES": "Credit notes only"}
                              [self.r_kind.get()], "all currencies" if self.r_cur.get() == "ALL" else self.r_cur.get())
        try:
            if kind == "xlsx":
                reports.export_xlsx(p, self.rep_data, per[0].isoformat(), per[1].isoformat(), business, filters)
            elif kind == "pdf":
                reports.export_pdf(p, self.rep_data, per[0].isoformat(), per[1].isoformat(), business, filters)
            else:
                reports.export_csv(p, self.rep_data)
        except PermissionError:
            messagebox.showerror(APP_NAME, "Cannot save: the file is open in another program. Close it and try again.")
            return
        self.log("Report saved: %s" % p, "info")
        self._open_file(p)

    def _open_file(self, p):
        from .gui import open_path
        open_path(p)

    def _bg(self, fn):
        threading.Thread(target=fn, daemon=True).start()
