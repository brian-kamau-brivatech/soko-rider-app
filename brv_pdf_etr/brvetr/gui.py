"""BRV PDF ETR window: invoices, settings, client templates (with Test a PDF and stamp preview)."""
import copy
import json
import os
import queue
import subprocess
import sys
import tempfile
import tkinter as tk
from datetime import datetime
from tkinter import filedialog, messagebox, ttk

from . import APP_NAME, VERSION, kra
from .config import DEFAULT_TEMPLATE
from .designer import Designer
from .parser import line_incl, line_tax, parse
from . import licence, visual
from .gui_more import BG, GOLD, GREEN, MUTED, NAVY, NAVY2, ORANGE, RED, MoreScreens, logo_image
from .stamp import stamp_pdf


TEMPLATE_FIELDS = [
    ("name", "Template name", "Shown in the list, e.g. the client's name."),
    ("match", "Recognise by text", "Text (regex) found only on this client's PDFs, e.g. their company name. Empty = default template."),
    ("invoice_no", "Invoice number", "Regex; the part in ( ) is the invoice number."),
    ("credit_note_no", "Credit note number", "Regex used when the PDF is a credit note."),
    ("date", "Date", "Regex (for display only)."),
    ("customer_name", "Customer name", "Regex; if the name is on the next line, leave ( ) empty: (.*)"),
    ("customer_pin", "Customer PIN", "Regex for KRA PINs; the seller's own PIN is ignored."),
    ("total", "Invoice total", "Regex for the grand total; used to check every line was read."),
    ("credit_note", "Is a credit note if", "Regex, e.g. credit\\s*note"),
    ("original_invoice", "Original invoice no.", "Regex on credit notes for the invoice being credited."),
    ("line", "Item line", "Regex with (?P<desc>) (?P<qty>) (?P<price>) (?P<amount>) and optional (?P<tax>) (?P<code>)."),
    ("lines_start", "Items start after", "Regex for the table header line."),
    ("lines_stop", "Items stop at", "Regex for the first line after the items (e.g. Sub total)."),
]


def open_path(path):
    try:
        if sys.platform.startswith("win"):
            os.startfile(path)  # noqa
        elif sys.platform == "darwin":
            subprocess.Popen(["open", path])
        else:
            subprocess.Popen(["xdg-open", path])
    except Exception as e:
        messagebox.showerror(APP_NAME, "Cannot open %s\n%s" % (path, e))


def set_autostart(enable):
    if not sys.platform.startswith("win"):
        return
    import winreg
    key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Run", 0,
                         winreg.KEY_SET_VALUE)
    try:
        if enable:
            if getattr(sys, "frozen", False):
                cmd = '"%s" --minimized' % sys.executable
            else:
                cmd = '"%s" "%s" --minimized' % (sys.executable, os.path.abspath(sys.argv[0]))
            winreg.SetValueEx(key, APP_NAME, 0, winreg.REG_SZ, cmd)
        else:
            try:
                winreg.DeleteValue(key, APP_NAME)
            except FileNotFoundError:
                pass
    finally:
        winreg.CloseKey(key)


class App(MoreScreens):
    def __init__(self, root, settings, engine):
        self.root, self.s, self.engine = root, settings, engine
        self.events = queue.Queue()
        self.admin = False
        engine.on_event = lambda kind, msg: self.events.put((kind, msg))
        root.title("%s %s  -  BRV Integrated Systems" % (APP_NAME, VERSION))
        root.geometry("1180x720")
        root.minsize(940, 580)
        root.configure(bg=BG)
        self._style()
        self._header()
        nb = self.nb = ttk.Notebook(root)
        nb.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        self.tab_inv = ttk.Frame(nb, padding=8)
        self.tab_rep = ttk.Frame(nb, padding=8)
        self.tab_items = ttk.Frame(nb, padding=8)
        self.tab_tpl = ttk.Frame(nb, padding=8)
        self.tab_set = ttk.Frame(nb, padding=12)
        nb.add(self.tab_inv, text="  Invoices  ")
        nb.add(self.tab_rep, text="  Reports  ")
        # Only after the admin password: the client cannot change how invoices are signed.
        self.admin_tabs = [(self.tab_items, "  Items  "), (self.tab_tpl, "  Client templates  "),
                           (self.tab_set, "  Settings  ")]
        self._invoices_tab()
        self._reports_tab()
        self._items_tab()
        self._settings_tab()
        self._templates_tab()
        self.lock()
        self.refresh()
        self.licence_banner()
        root.after(400, self._pump)
        root.protocol("WM_DELETE_WINDOW", self._close)
        root.bind_all("<Key>", self.admin_touch, add="+")
        root.bind_all("<Button>", self.admin_touch, add="+")
        if self.s.tampered:
            messagebox.showerror(APP_NAME, "The settings file was changed outside the app (or copied from another "
                                           "computer), so it cannot be used. Signing is off until BRV sets the app up "
                                           "again.", parent=root)
        if not self.s.get("admin_pw"):
            root.after(300, self._first_start)
        elif self.s.ready and self.s.get("auto_start", True):
            self.engine.start()

    def _first_start(self):
        self.admin_setup_if_needed()
        if self.admin and not self.s.ready:
            self.nb.select(self.tab_set)
            self.log("Welcome. Enter the VSCU address, PIN, branch and device serial, then click Save and connect. "
                     "Then click Licence... to activate the licence.", "info")
        elif self.s.ready and self.s.get("auto_start", True):
            self.engine.start()

    # ------------------------------------------------------------------ look
    def _style(self):
        st = ttk.Style()
        try:
            st.theme_use("clam")
        except tk.TclError:
            pass
        st.configure(".", background=BG)
        st.configure("TFrame", background=BG)
        st.configure("TLabel", background=BG)
        st.configure("TCheckbutton", background=BG)
        st.configure("TNotebook", background=BG, borderwidth=0)
        st.configure("TNotebook.Tab", padding=(14, 6), font=("Segoe UI", 10, "bold"), background="#DDE3EC",
                     foreground=NAVY)
        st.map("TNotebook.Tab", background=[("selected", "white")], foreground=[("selected", NAVY)])
        st.configure("Treeview", rowheight=26, font=("Segoe UI", 9), fieldbackground="white")
        st.configure("Treeview.Heading", font=("Segoe UI", 9, "bold"), background=NAVY, foreground="white",
                     relief="flat")
        st.map("Treeview.Heading", background=[("active", NAVY2)])
        st.map("Treeview", background=[("selected", "#E7ECF4")], foreground=[("selected", NAVY)])
        st.configure("TButton", padding=(8, 3))
        st.configure("Accent.TButton", font=("Segoe UI", 10, "bold"), foreground="white", background=NAVY)
        st.map("Accent.TButton", background=[("active", NAVY2)])
        st.configure("Gold.TButton", font=("Segoe UI", 10, "bold"), foreground="white", background=GOLD)
        st.map("Gold.TButton", background=[("active", "#9E6E1C")])
        st.configure("Head.TButton", font=("Segoe UI", 9), foreground="white", background=NAVY2, borderwidth=0)
        st.map("Head.TButton", background=[("active", "#2A5596")])
        st.configure("Big.TLabel", font=("Segoe UI", 15, "bold"), foreground="white", background=NAVY)
        st.configure("Head.TFrame", background=NAVY)
        st.configure("HeadSmall.TLabel", font=("Segoe UI", 9), foreground=GOLD, background=NAVY)

    def _header(self):
        h = ttk.Frame(self.root, style="Head.TFrame", padding=(12, 8))
        h.pack(fill="x", pady=(0, 6))
        tk.Frame(self.root, bg=GOLD, height=3).place(in_=h, relx=0, rely=1.0, relwidth=1, anchor="sw")
        self._logo = logo_image("brv_mark.png", 42)
        if self._logo:
            tile = tk.Label(h, image=self._logo, bg="white", bd=0, padx=4, pady=2, cursor="hand2")
            tile.pack(side="left", padx=(0, 10))
            tile.bind("<Button-1>", lambda e: self.about())
        txt = ttk.Frame(h, style="Head.TFrame")
        txt.pack(side="left")
        ttk.Label(txt, text="BRV PDF ETR", style="Big.TLabel").pack(anchor="w")
        ttk.Label(txt, text="KRA eTIMS invoice signing  ·  BRV Integrated Systems", style="HeadSmall.TLabel").pack(anchor="w")
        self.btn_admin = ttk.Button(h, text="Admin", style="Head.TButton", command=self.admin_click)
        self.btn_admin.pack(side="right", padx=(10, 0))
        ttk.Button(h, text="Licence...", style="Head.TButton", command=self.licence_dialog).pack(side="right", padx=2)
        self.btn_run = ttk.Button(h, text="Start", style="Gold.TButton", command=self.toggle)
        self.btn_run.pack(side="right", padx=(4, 10))
        ttk.Button(h, text="Check now", style="Head.TButton", command=lambda: self._bg(self.engine.scan_once)).pack(side="right", padx=2)
        for label, key in (("Error", "error_dir"), ("Output", "output_dir"), ("Input", "input_dir")):
            ttk.Button(h, text=label, style="Head.TButton", command=lambda k=key: self._open_dir(k)).pack(side="right", padx=2)
        bar = tk.Frame(self.root, bg=BG)
        bar.pack(fill="x", padx=12)
        self.lbl_status = tk.Label(bar, text="", anchor="w", font=("Segoe UI", 10, "bold"), fg=NAVY, bg=BG)
        self.lbl_status.pack(side="left")
        self.lbl_lic = tk.Label(bar, text="", anchor="e", font=("Segoe UI", 9, "bold"), bg=BG, padx=8, cursor="hand2")
        self.lbl_lic.pack(side="right")
        self.lbl_lic.bind("<Button-1>", lambda e: self.licence_dialog())

    def _open_dir(self, key):
        os.makedirs(self.s[key], exist_ok=True)
        open_path(self.s[key])

    # ------------------------------------------------------------------ invoices tab
    def _invoices_tab(self):
        f = self.tab_inv
        top = ttk.Frame(f)
        top.pack(fill="x")
        ttk.Label(top, text="Search:").pack(side="left")
        self.q = tk.StringVar()
        e = ttk.Entry(top, textvariable=self.q, width=30)
        e.pack(side="left", padx=6)
        e.bind("<KeyRelease>", lambda _e: self.refresh())
        ttk.Label(top, text="  Show").pack(side="left")
        self.inv_filter = tk.StringVar(value="All")
        cf = ttk.Combobox(top, textvariable=self.inv_filter, width=13, state="readonly",
                          values=["All", "Invoices", "Credit notes", "KES", "USD", "Not signed"])
        cf.pack(side="left", padx=4)
        cf.bind("<<ComboboxSelected>>", lambda _e: self.refresh())
        ttk.Button(top, text="Open signed PDF", style="Accent.TButton", command=self.open_selected).pack(side="right", padx=3)
        ttk.Button(top, text="Details", command=self.details).pack(side="right", padx=3)
        ttk.Button(top, text="Retry now", command=self.retry).pack(side="right", padx=3)

        cols = ("time", "file", "type", "inv", "kra", "cust", "pin", "cur", "total", "vat", "status", "msg")
        heads = ("Time", "PDF file", "Type", "Invoice no.", "KRA no.", "Customer", "PIN", "Cur.", "Total KES", "VAT",
                 "Status", "Message")
        widths = (115, 170, 80, 85, 60, 150, 95, 70, 85, 70, 65, 280)
        frame = ttk.Frame(f)
        frame.pack(fill="both", expand=True, pady=6)
        self.tree = ttk.Treeview(frame, columns=cols, show="headings", selectmode="browse")
        for c, h_, w in zip(cols, heads, widths):
            self.tree.heading(c, text=h_)
            self.tree.column(c, width=w, anchor="e" if c in ("total", "vat", "kra") else "w", stretch=c in ("msg", "file", "cust"))
        sb = ttk.Scrollbar(frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.tree.tag_configure("signed", foreground=GREEN)
        self.tree.tag_configure("waiting", foreground=ORANGE)
        self.tree.tag_configure("failed", foreground=RED)
        self.tree.bind("<Double-1>", lambda _e: self.open_selected())
        act = ttk.Frame(f)
        act.pack(fill="x")
        ttk.Label(act, text="Activity").pack(side="left")
        self.lbl_totals = ttk.Label(act, text="", font=("Segoe UI", 9, "bold"), foreground=NAVY)
        self.lbl_totals.pack(side="right")
        self.txt = tk.Text(f, height=7, font=("Consolas", 9), bg="#F7F9FC", relief="flat", wrap="word")
        self.txt.pack(fill="x")
        for tag, col in (("signed", GREEN), ("error", RED), ("waiting", ORANGE), ("info", NAVY)):
            self.txt.tag_configure(tag, foreground=col)

    def refresh(self):
        self.tree.delete(*self.tree.get_children())
        signed = tot = vat = 0
        today = datetime.now().strftime("%Y-%m-%d")
        flt = self.inv_filter.get() if hasattr(self, "inv_filter") else "All"
        for r in self.engine.db.recent(search=self.q.get().strip() if hasattr(self, "q") else ""):
            cur = r["currency"] or "KES"
            if (flt == "Invoices" and r["kind"] != "S") or (flt == "Credit notes" and r["kind"] != "R") or \
                    (flt in ("KES", "USD") and (cur != flt or r["status"] != "signed")) or \
                    (flt == "Not signed" and r["status"] == "signed"):
                continue
            when = (r["signed_at"] or r["created_at"] or "").replace("T", " ")[:16]
            fc = ("%s %s" % (cur, "{:,.2f}".format(r["tot_amt_fc"]))) if cur != "KES" and r["tot_amt_fc"] else cur
            self.tree.insert("", "end", iid=str(r["id"]), tags=(r["status"],), values=(
                when, r["file_name"] or "", "Credit note" if r["kind"] == "R" else "Invoice",
                r["trd_invc_no"] or "", r["invc_no"] or "",
                r["cust_nm"] or "", r["cust_tin"] or "", fc,
                "%s%.2f" % ("-" if r["kind"] == "R" else "", r["tot_amt"]) if r["tot_amt"] is not None else "",
                "%.2f" % r["tot_tax"] if r["tot_tax"] is not None else "",
                {"signed": "Signed", "waiting": "Waiting", "failed": "Failed"}.get(r["status"], r["status"] or ""),
                (r["error"] or "").replace("\n", " ")))
            if r["status"] == "signed" and (r["signed_at"] or "").startswith(today):
                signed += 1
                sign = -1 if r["kind"] == "R" else 1
                tot += sign * (r["tot_amt"] or 0)
                vat += sign * (r["tot_tax"] or 0)
        self.lbl_totals.configure(text="Today: %d signed   |   Total KES %s   |   VAT KES %s" % (
            signed, "{:,.2f}".format(tot), "{:,.2f}".format(vat)))

    def _sel(self):
        s = self.tree.selection()
        return self.engine.db.invoice(int(s[0])) if s else None

    def open_selected(self):
        r = self._sel()
        if not r:
            return
        if r["output_path"] and os.path.exists(r["output_path"]):
            open_path(r["output_path"])
        else:
            messagebox.showinfo(APP_NAME, "No signed PDF for this line." +
                                ("\n\n" + r["error"] if r["error"] else ""))

    def retry(self):
        r = self._sel()
        if r and r["status"] == "waiting":
            self._bg(lambda: self.engine.resend(r["id"]))
        else:
            self._bg(self.engine.scan_once)

    def details(self):
        r = self._sel()
        if not r:
            return
        w = tk.Toplevel(self.root)
        w.title("Invoice details")
        w.geometry("760x560")
        t = tk.Text(w, font=("Consolas", 9), wrap="word")
        t.pack(fill="both", expand=True)
        d = {k: r[k] for k in r.keys() if k not in ("payload", "response")}
        t.insert("end", json.dumps(d, indent=2, default=str))
        for k in ("payload", "response"):
            if r[k]:
                t.insert("end", "\n\n--- %s sent to/received from KRA ---\n" % k)
                try:
                    t.insert("end", json.dumps(json.loads(r[k]), indent=2))
                except ValueError:
                    t.insert("end", r[k])
        if r["rcpt_sign"]:
            url = kra.receipt_url(self.s["tin"], self.s["bhf_id"], r["rcpt_sign"])
            t.insert("end", "\n\nKRA check link: %s\n" % url)

    def log(self, msg, kind="info"):
        self.txt.insert("1.0", "%s  %s\n" % (datetime.now().strftime("%H:%M:%S"), msg), kind)
        self.txt.delete("200.0", "end")

    def _pump(self):
        changed = False
        try:
            while True:
                kind, msg = self.events.get_nowait()
                if kind == "status":
                    self._status(msg)
                else:
                    self.log(msg, kind)
                    changed = True
        except queue.Empty:
            pass
        if changed:
            self.refresh()
        self.btn_run.configure(text="Stop" if self.engine.running else "Start")
        self.admin_tick()
        self._tick = getattr(self, "_tick", 0) + 1
        if self._tick % 120 == 1:
            self.licence_banner()
        if not self.engine.running and not self.lbl_status.cget("text"):
            self._status("Stopped")
        self.root.after(500, self._pump)

    def _status(self, msg):
        if msg.startswith("NOT SIGNING"):
            self.licence_banner()
        col = GREEN if msg.startswith(("Watching", "Signing")) else RED if msg.startswith("NOT SIGNING") else \
            ORANGE if "waiting" in msg.lower() or "not" in msg.lower() else NAVY
        self.lbl_status.configure(text="●  " + msg, fg=col)

    def toggle(self):
        if self.engine.running:
            self.engine.stop()
            self._status("Stopped")
        else:
            if not self.s.ready:
                messagebox.showwarning(APP_NAME, "Connect to the VSCU first (Settings).")
                return
            self.engine.start()

    def _bg(self, fn):
        import threading
        threading.Thread(target=fn, daemon=True).start()

    def _close(self):
        if self.engine.running and not messagebox.askyesno(
                APP_NAME, "Close BRV PDF ETR?\n\nInvoices put in the Input folder will not be signed until it runs again."):
            return
        self.engine.stop()
        self.root.destroy()

    # ------------------------------------------------------------------ settings tab
    def _settings_tab(self):
        f = self.tab_set
        self.sv = {}
        r = 0

        def row(key, label, hint="", width=48, browse=False, show=None):
            nonlocal r
            ttk.Label(f, text=label).grid(row=r, column=0, sticky="w", pady=2)
            v = tk.StringVar(value=str(self.s.get(key, "")))
            e = ttk.Entry(f, textvariable=v, width=width, show=show)
            e.grid(row=r, column=1, sticky="w", pady=2)
            if browse:
                ttk.Button(f, text="Browse", command=lambda: v.set(filedialog.askdirectory(initialdir=v.get()) or v.get())
                           ).grid(row=r, column=2, sticky="w", padx=4)
            if hint:
                ttk.Label(f, text=hint, foreground="#666").grid(row=r, column=3, sticky="w", padx=8)
            self.sv[key] = v
            r += 1

        ttk.Label(f, text="KRA VSCU connection", font=("Segoe UI", 11, "bold"), foreground=NAVY).grid(row=r, column=0, sticky="w", pady=(0, 6))
        r += 1
        row("vscu_url", "VSCU address", "e.g. http://178.128.254.30:8088")
        row("tin", "Business KRA PIN", "e.g. P051234567X", 20)
        row("bhf_id", "Branch ID", "00 = head office", 8)
        row("serial", "Device serial", "From the eTIMS registration", 30)
        bar = ttk.Frame(f)
        bar.grid(row=r, column=1, columnspan=3, sticky="w", pady=4)
        ttk.Button(bar, text="Save and connect", style="Accent.TButton", command=self.connect).pack(side="left")
        self.lbl_conn = ttk.Label(bar, text=self._conn_text(), foreground=GREEN if self.s.ready else RED)
        self.lbl_conn.pack(side="left", padx=10)
        r += 1
        ttk.Separator(f).grid(row=r, column=0, columnspan=4, sticky="ew", pady=6)
        r += 1
        ttk.Label(f, text="Folders and signing", font=("Segoe UI", 11, "bold"), foreground=NAVY).grid(row=r, column=0, sticky="w", pady=(0, 6))
        bar2 = ttk.Frame(f)
        bar2.grid(row=r, column=1, columnspan=3, sticky="w", pady=(0, 6))
        ttk.Button(bar2, text="Save settings", style="Accent.TButton", command=self.save_settings).pack(side="left")
        ttk.Button(bar2, text="Next KRA invoice number...", command=self.set_counter).pack(side="left", padx=8)
        ttk.Button(bar2, text="Change admin password...", command=self.change_password).pack(side="left")
        ttk.Button(bar2, text="Licence...", command=self.licence_dialog).pack(side="left", padx=8)
        r += 1
        row("input_dir", "Input folder", "Invoice PDFs to sign", browse=True)
        row("output_dir", "Output folder", "Signed PDFs", browse=True)
        row("error_dir", "Error folder", "Not signed, with the reason", browse=True)
        row("archive_dir", "Archive folder", "Original PDFs after signing", browse=True)
        row("output_suffix", "Signed file name ending", "e.g. _signed (empty = same name)", 14)
        row("item_class", "Default item classification", "KRA code for new items", 16)
        row("poll_seconds", "Check every (seconds)", "", 6)
        row("tax_rules", "VAT-free items", "e.g. milk=C, bread=C, eggs=A", 48)
        row("rates", "Exchange rates to KES", "e.g. USD=129.00, EUR=140.00 (when the invoice has no rate)", 48)
        self.v_incl = tk.BooleanVar(value=bool(self.s.get("send_incl_vat", True)))
        ttk.Checkbutton(f, text="Send line prices VAT inclusive (same as BRV POS)", variable=self.v_incl).grid(row=r, column=1, sticky="w")
        r += 1
        self.v_auto = tk.BooleanVar(value=bool(self.s.get("auto_start", True)))
        ttk.Checkbutton(f, text="Start signing automatically when the app opens", variable=self.v_auto).grid(row=r, column=1, sticky="w")
        r += 1
        self.v_win = tk.BooleanVar(value=bool(self.s.get("windows_start", False)))
        ttk.Checkbutton(f, text="Open BRV PDF ETR when Windows starts", variable=self.v_win).grid(row=r, column=1, sticky="w")
        from . import ocr
        ttk.Label(f, text=ocr.status_text(), foreground=GREEN if ocr.available() else MUTED).grid(
            row=r, column=2, columnspan=2, sticky="w", padx=8)
        r += 1

    def _conn_text(self):
        if not self.s.ready:
            return "Not connected"
        return "Connected: %s  |  SCU %s  |  next KRA invoice no. %s" % (
            self.s.get("taxpayer_name") or "", self.s.get("sdc_id") or "-", self.engine.db.next_invoice_no())

    def _read_settings(self):
        for k, v in self.sv.items():
            val = v.get().strip()
            if k == "poll_seconds":
                try:
                    val = max(1, int(val))
                except ValueError:
                    val = 3
            if k in ("tin",):
                val = val.upper()
            self.s[k] = val
        self.s["send_incl_vat"] = bool(self.v_incl.get())
        self.s["auto_start"] = bool(self.v_auto.get())
        self.s["windows_start"] = bool(self.v_win.get())
        if self.sv.get("rates") and self.sv["rates"].get().strip() != (self.s.get("rates_seen") or ""):
            self.s["rates_date"] = datetime.now().strftime("%Y-%m-%d")
            self.s["rates_seen"] = self.sv["rates"].get().strip()

    def save_settings(self):
        self._read_settings()
        self.s.save()
        try:
            self.s.make_folders()
        except OSError as e:
            messagebox.showerror(APP_NAME, "Cannot create the folders:\n%s" % e)
        try:
            set_autostart(self.s["windows_start"])
        except Exception as e:
            self.log("Could not change Windows start-up: %s" % e, "error")
        self.log("Settings saved.", "info")

    def connect(self):
        self._read_settings()
        if not (self.s["vscu_url"] and self.s["tin"] and self.s["serial"]):
            messagebox.showwarning(APP_NAME, "Enter the VSCU address, KRA PIN and device serial.")
            return
        self.s["initialised"] = False
        self.s.save()
        self.lbl_conn.configure(text="Connecting...", foreground=ORANGE)

        def work():
            res = self.engine.initialise()
            self.s.save()
            self.events.put(("info" if (res.ok or self.engine.vscu.already_installed(res)) else "error",
                             "VSCU: %s" % res.message))
            self.root.after(0, lambda: self.lbl_conn.configure(
                text=self._conn_text() if self.s.ready else "Not connected: %s" % res.message,
                foreground=GREEN if self.s.ready else RED))
            if self.s.ready and self.s.get("auto_start", True):
                self.engine.start()
        self._bg(work)

    def set_counter(self):
        from tkinter import simpledialog
        n = simpledialog.askinteger(APP_NAME, "Next KRA invoice number (only change this if KRA support tells you):",
                                    initialvalue=self.engine.db.next_invoice_no(), minvalue=1, parent=self.root)
        if n:
            self.engine.db.force_next_invoice_no(n)
            self.lbl_conn.configure(text=self._conn_text())

    # ------------------------------------------------------------------ templates tab
    def _templates_tab(self):
        f = self.tab_tpl
        left = ttk.Frame(f)
        left.pack(side="left", fill="y")
        ttk.Label(left, text="Templates (first match wins)", font=("Segoe UI", 9, "bold")).pack(anchor="w")
        self.lst = tk.Listbox(left, width=40, height=9, exportselection=False, font=("Segoe UI", 9))
        self.lst.pack(fill="y", expand=True, pady=4)
        self.lst.bind("<<ListboxSelect>>", lambda _e: self._load_tpl())
        ttk.Button(left, text="New: design on a PDF...", style="Accent.TButton", command=self.tpl_new).pack(fill="x", pady=1)
        ttk.Button(left, text="Open in designer...", command=self.tpl_design).pack(fill="x", pady=1)
        for label, cmd in (("Import template...", self.tpl_import), ("Export template...", self.tpl_export),
                           ("New with text patterns", self.tpl_new_regex), ("Copy", self.tpl_copy), ("Delete", self.tpl_delete),
                           ("Move up", lambda: self.tpl_move(-1)), ("Move down", lambda: self.tpl_move(1))):
            ttk.Button(left, text=label, command=cmd).pack(fill="x", pady=1)

        right = ttk.Frame(f)
        right.pack(side="left", fill="both", expand=True, padx=(12, 0))
        bar = ttk.Frame(right)
        bar.pack(side="top", fill="x", pady=(0, 6))
        ttk.Button(bar, text="Save template", style="Accent.TButton", command=self.tpl_save).pack(side="left")
        ttk.Button(bar, text="Open in designer...", command=self.tpl_design).pack(side="left", padx=(6, 0))
        ttk.Button(bar, text="Test a PDF...", command=self.tpl_test).pack(side="left", padx=6)
        ttk.Button(bar, text="Which template?", command=self.tpl_which).pack(side="left", padx=(0, 6))
        ttk.Button(bar, text="Preview stamp...", command=self.tpl_preview).pack(side="left")
        canvas = tk.Canvas(right, highlightthickness=0)
        sb = ttk.Scrollbar(right, orient="vertical", command=canvas.yview)
        form = ttk.Frame(canvas)
        form.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=form, anchor="nw")
        canvas.configure(yscrollcommand=sb.set)
        canvas.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.tv = {}
        self.tf_widgets = {}
        self.lbl_kind = tk.Label(form, text="", fg=NAVY, font=("Segoe UI", 9, "bold"), justify="left", anchor="w")
        self.lbl_kind.grid(row=0, column=0, columnspan=3, sticky="w", pady=(0, 6))
        r = 1
        for key, label, hint in TEMPLATE_FIELDS:
            a = ttk.Label(form, text=label)
            a.grid(row=r, column=0, sticky="nw", pady=2)
            v = tk.StringVar()
            b = ttk.Entry(form, textvariable=v, width=78 if key in ("line", "total", "invoice_no") else 60)
            b.grid(row=r, column=1, sticky="w", pady=2)
            c = ttk.Label(form, text=hint, foreground="#777", wraplength=330)
            c.grid(row=r, column=2, sticky="w", padx=6)
            self.tv[key] = v
            self.tf_widgets[key] = (a, b, c)
            r += 1
        self.tv_incl = tk.BooleanVar()
        ttk.Checkbutton(form, text="Prices and amounts on these invoices INCLUDE VAT", variable=self.tv_incl
                        ).grid(row=r, column=1, sticky="w", pady=4)
        r += 1

        def combo(key, label, values, hint=""):
            nonlocal r
            ttk.Label(form, text=label).grid(row=r, column=0, sticky="w", pady=2)
            v = tk.StringVar()
            ttk.Combobox(form, textvariable=v, values=values, width=30).grid(row=r, column=1, sticky="w", pady=2)
            if hint:
                ttk.Label(form, text=hint, foreground="#777", wraplength=330).grid(row=r, column=2, sticky="w", padx=6)
            self.tv[key] = v
            r += 1

        combo("default_tax", "Lines with no VAT code", ["AUTO", "B", "A", "C", "D", "E"],
              "AUTO = from the VAT on the invoice. B 16%, E 8%, C zero rated, A exempt, D non-VAT")
        combo("free_code", "VAT-free items are", ["C", "A"], "C = zero rated (e.g. milk), A = exempt")
        combo("tax_map", "VAT column → code", [], "e.g. 16%=B, 0%=C, E=A")
        combo("item_class", "Item classification", [], "KRA code for new items (empty = Settings default)")
        combo("qty_unit", "Quantity unit", ["U", "KG", "LTR", "MTR", "BX", "BG", "PA", "SET"], "U = pieces")
        combo("pkg_unit", "Packaging unit", ["NT", "CT", "BX", "BG", "BQ"], "NT = net")
        combo("item_type", "Item type", ["2", "1", "3"], "1 raw material, 2 finished product, 3 service")
        combo("folder", "Input sub-folder", [], "e.g. Yiwak: PDFs saved in Input\\Yiwak always use this template "
              "(no identifier needed). Empty = chosen by DOCUMENT IDENTIFIER.")
        combo("doc_type", "Document type", ["auto", "invoice", "credit"],
              "invoice = always invoice (never signs a credit note); credit = always credit note; auto = detect")
        combo("currency", "Invoice currency", ["KES", "USD", "EUR", "GBP", "INVOICE"],
              "INVOICE = read from the CURRENCY row (KSH or USD). Foreign amounts go to KRA in KES.")
        combo("payment", "Payment type", list(kra.PAYMENT_TYPES), ", ".join("%s %s" % kv for kv in kra.PAYMENT_TYPES.items()))
        combo("refund_reason", "Credit note reason", ["06", "01", "03", "07", "09", "10", "11", "13"], "06 refund, 09 wrong amount, 13 other")
        ttk.Label(form, text="KRA stamp position", font=("Segoe UI", 9, "bold"), foreground=NAVY).grid(row=r, column=0, sticky="w", pady=(10, 2))
        r += 1
        combo("stamp.page", "Page", ["last", "first", "all"])
        combo("stamp.style", "Look", ["clean", "box"],
              "clean = plain CU block like a KRA receipt; box = framed box")
        combo("stamp.title", "Block title", ["SCU INFORMATION", "CU INFORMATION"],
              "KRA specification: SCU Information")
        combo("stamp.anchor", "Position", ["auto", "text", "fixed", "after", "bottom-right", "bottom-left",
                                          "bottom-center", "top-right", "top-left"],
              "Easiest: Open in designer > KRA box > drag it. auto = empty spot; text = under a text; fixed = exact spot")
        combo("stamp.anchor_text", "Under this text", [], "for Position = text, e.g. Invoice Total")
        combo("stamp.x_mm", "Left / side (mm)", ["10"], "fixed: from the page left; text: from the text; corners: margin")
        combo("stamp.y_mm", "Top / down (mm)", ["10"], "fixed: from the page top; text: below the text; corners: margin")
        combo("stamp.width_mm", "Box width (mm)", ["75"])
        self._fill_list()

    def _fill_list(self, select=0):
        self.lst.delete(0, "end")
        for t in self.s["templates"]:
            dt = {"invoice": "Invoice", "credit": "Credit note"}.get((t.get("doc_type") or "auto").lower(), "Detect")
            fd = (t.get("folder") or "").strip()
            self.lst.insert("end", "%s   ·  %s%s" % (t.get("name") or "(no name)", dt, ("  ·  Input\\" + fd) if fd else ""))
        if self.s["templates"]:
            self.lst.selection_set(min(select, len(self.s["templates"]) - 1))
            self._load_tpl()

    def _cur(self):
        sel = self.lst.curselection()
        return sel[0] if sel else 0

    def _load_tpl(self):
        t = self.s["templates"][self._cur()]
        for k, v in self.tv.items():
            if k.startswith("stamp."):
                v.set(str(t["stamp"].get(k[6:], "")))
            elif k == "tax_map":
                v.set(", ".join("%s=%s" % kv for kv in (t.get("tax_map") or {}).items()))
            else:
                v.set(str(t.get(k, "")))
        self.tv_incl.set(bool(t.get("prices_include_vat", True)))
        vis = t.get("kind") == "visual"
        for key, ws in self.tf_widgets.items():
            for w in ws:
                (w.grid_remove if vis and key != "name" else w.grid)()
        if vis:
            n = len(t.get("fields") or [])
            self.lbl_kind.configure(text="Made in the designer (%d rows). Click 'Open in designer...' to change what is "
                                         "read. The options below apply too." % n)
        else:
            self.lbl_kind.configure(text="Text-pattern template (advanced). Tip: 'New: design on a PDF...' is easier.")

    def _form_tpl(self):
        t = copy.deepcopy(self.s["templates"][self._cur()])
        for k, v in self.tv.items():
            val = v.get()
            if k.startswith("stamp."):
                sub = k[6:]
                if sub.endswith("_mm"):
                    try:
                        val = float(val)
                    except ValueError:
                        val = DEFAULT_TEMPLATE["stamp"][sub]
                t["stamp"][sub] = val
            elif k == "tax_map":
                mp = {}
                for part in val.split(","):
                    if "=" in part:
                        a, b = part.split("=", 1)
                        if a.strip() and b.strip():
                            mp[a.strip()] = b.strip().upper()
                t["tax_map"] = mp
            else:
                t[k] = val.strip() if k not in ("line",) else val
        t["prices_include_vat"] = bool(self.tv_incl.get())
        return t

    def tpl_save(self):
        import re
        t = self._form_tpl()
        for key, label, _h in TEMPLATE_FIELDS:
            if key == "name" or t.get("kind") == "visual":
                continue
            try:
                re.compile(t.get(key) or "")
            except re.error as e:
                messagebox.showerror(APP_NAME, "%s: the pattern is not valid.\n%s" % (label, e))
                return
        fd = (t.get("folder") or "").strip().strip("\\/")
        if fd and (any(ch in fd for ch in '<>:"/\\|?*') or fd.lower() in ("output", "error", "archive")):
            messagebox.showerror(APP_NAME, "The Input sub-folder name cannot contain < > : \" / \\ | ? *")
            return
        other = [x for j, x in enumerate(self.s["templates"]) if j != self._cur() and fd and
                 (x.get("folder") or "").strip().lower() == fd.lower()]
        if other:
            messagebox.showerror(APP_NAME, "Template '%s' already uses the folder Input\\%s." % (other[0]["name"], fd))
            return
        t["folder"] = fd
        i = self._cur()
        self.s["templates"][i] = t
        self.s.save()
        try:
            self.s.make_folders()
        except OSError:
            pass
        self._fill_list(i)
        self.log("Template '%s' saved.%s" % (t["name"], (" PDFs in %s use it." % os.path.join(self.s["input_dir"], fd))
                                              if fd else ""), "info")

    def tpl_new(self):
        t = copy.deepcopy(DEFAULT_TEMPLATE)
        t.update({"kind": "visual", "name": "New client", "match": "", "fields": [], "default_tax": "AUTO"})

        def saved(new):
            self.s["templates"].insert(0, new)
            self.s.save()
            self._fill_list(0)
            self.log("Template '%s' added." % new["name"], "info")
        Designer(self.root, t, self.s.get("tin", ""), saved, self.s.get("tax_rules", ""))

    def tpl_design(self):
        i = self._cur()
        t = self._form_tpl()
        if t.get("kind") != "visual":
            if not messagebox.askyesno(APP_NAME, "'%s' uses text patterns. Make a new designer template for this "
                                       "client instead? (the pattern template is kept)" % t["name"]):
                return
            t = copy.deepcopy(t)
            t.update({"kind": "visual", "fields": [], "match": "", "sample": ""})
            i = None

        def saved(new):
            if i is None:
                self.s["templates"].insert(0, new)
                j = 0
            else:
                self.s["templates"][i] = new
                j = i
            self.s.save()
            self._fill_list(j)
            self.log("Template '%s' saved." % new["name"], "info")
        Designer(self.root, t, self.s.get("tin", ""), saved, self.s.get("tax_rules", ""))

    def tpl_export(self):
        t = copy.deepcopy(self.s["templates"][self._cur()])
        t.pop("sample", None)
        p = filedialog.asksaveasfilename(title="Export template", defaultextension=".brvtpl",
                                         initialfile="%s.brvtpl" % (t.get("name") or "template"),
                                         filetypes=[("BRV template", "*.brvtpl")])
        if p:
            with open(p, "w", encoding="utf-8") as f:
                json.dump({"brv_pdf_etr_template": 1, "template": t}, f, indent=1)
            self.log("Template exported: %s" % p, "info")

    def tpl_import(self):
        p = filedialog.askopenfilename(title="Import template", filetypes=[("BRV template", "*.brvtpl *.json")])
        if not p:
            return
        try:
            with open(p, encoding="utf-8") as f:
                data = json.load(f)
            t = data.get("template", data)
            if not isinstance(t, dict) or not (t.get("fields") or t.get("line")):
                raise ValueError("not a BRV PDF ETR template")
        except Exception as e:
            messagebox.showerror(APP_NAME, "Cannot import this file:\n%s" % e)
            return
        full = copy.deepcopy(DEFAULT_TEMPLATE)
        full.update(t)
        full["stamp"] = {**DEFAULT_TEMPLATE["stamp"], **(t.get("stamp") or {})}
        full.pop("sample", None)
        names = [x.get("name") for x in self.s["templates"]]
        if full.get("name") in names:
            full["name"] = "%s (imported)" % full["name"]
        self.s["templates"].insert(0, full)
        self.s.save()
        self._fill_list(0)
        self.log("Template '%s' imported. Open it in the designer with a sample PDF to check it." % full["name"], "info")

    def tpl_new_regex(self):
        t = copy.deepcopy(DEFAULT_TEMPLATE)
        t["name"] = "New client"
        t["match"] = "Client company name"
        self.s["templates"].insert(0, t)
        self.s.save()
        self._fill_list(0)

    def tpl_copy(self):
        t = copy.deepcopy(self.s["templates"][self._cur()])
        t["name"] += " (copy)"
        self.s["templates"].insert(self._cur() + 1, t)
        self.s.save()
        self._fill_list(self._cur() + 1)

    def tpl_delete(self):
        if len(self.s["templates"]) <= 1:
            messagebox.showinfo(APP_NAME, "Keep at least one template.")
            return
        i = self._cur()
        if messagebox.askyesno(APP_NAME, "Delete template '%s'?" % self.s["templates"][i]["name"]):
            del self.s["templates"][i]
            self.s.save()
            self._fill_list(max(0, i - 1))

    def tpl_move(self, d):
        i = self._cur()
        j = i + d
        tl = self.s["templates"]
        if 0 <= j < len(tl):
            tl[i], tl[j] = tl[j], tl[i]
            self.s.save()
            self._fill_list(j)

    def tpl_test(self):
        path = filedialog.askopenfilename(title="Choose an invoice PDF", filetypes=[("PDF", "*.pdf")])
        if not path:
            return
        t = self._form_tpl()
        try:
            if t.get("kind") == "visual":
                d = visual.Doc(path)
                p = visual.read(d, t, self.s.get("tin", ""))
                p.update({"template": t, "text": d.text})
            else:
                p = parse(path, [dict(t, match="")], own_tin=self.s.get("tin", ""))
        except Exception as e:
            messagebox.showerror(APP_NAME, "Could not read the PDF:\n%s" % e)
            return
        w = tk.Toplevel(self.root)
        w.title("Test: %s" % os.path.basename(path))
        w.geometry("1000x680")
        info = ttk.Frame(w, padding=10)
        info.pack(fill="x")
        rows = [("Invoice number", p["invoice_no"]), ("Credit note", "YES (original: %s)" % p["original_invoice"] if p["credit_note"] else "no"),
                ("Date", p["date"]), ("Customer", p["customer_name"]), ("Customer PIN", p["customer_pin"] or "(none: sale to a non-registered customer)"),
                ("Invoice total", "%.2f" % p["total"] if p["total"] is not None else "(not found)")]
        for i, (a, b) in enumerate(rows):
            ttk.Label(info, text=a + ":", font=("Segoe UI", 9, "bold")).grid(row=i // 3, column=(i % 3) * 2, sticky="w", padx=(0, 4))
            ttk.Label(info, text=b or "(not found)", foreground=RED if not b else "black").grid(row=i // 3, column=(i % 3) * 2 + 1, sticky="w", padx=(0, 24))
        cols = ("desc", "qty", "price", "amount", "taxraw", "code", "incl")
        tree = ttk.Treeview(w, columns=cols, show="headings", height=10)
        for c, h_, wd in zip(cols, ("Description", "Qty", "Price", "Amount", "VAT on PDF", "KRA code", "Total incl. VAT"),
                             (380, 60, 90, 90, 80, 70, 110)):
            tree.heading(c, text=h_)
            tree.column(c, width=wd, anchor="w" if c == "desc" else "e")
        tree.pack(fill="x", padx=10)
        total = 0
        from . import taxes
        tprob, tnotes = taxes.resolve(p, t, taxes.parse_rules(self.s.get("tax_rules", "")))
        p["notes"] = list(p["notes"]) + tprob + tnotes
        for ln in p["lines"]:
            code = line_tax(t, ln)
            rate = kra.TAX_RATES.get(code, 0)
            incl = ln["amount"] if line_incl(t, ln) else ln["amount"] * (100 + rate) / 100
            total += kra.r2(incl)
            tree.insert("", "end", values=(ln["desc"], "%g" % ln["qty"], "%.2f" % ln["price"], "%.2f" % ln["amount"],
                                           ln["tax_raw"], code, "%.2f" % incl))
        left_out = sum(a for _, a in p.get("excluded") or [])
        ok = not tprob and p["total"] is not None and abs(abs(p["total"]) - left_out - total) <= max(1.0, abs(p["total"]) * 0.001)
        verdict = ("✔ Lines add up to %.2f = invoice total. Ready to sign." % total if ok else
                   "✘ Lines add up to %.2f but the invoice total is %s. Adjust the item line pattern." %
                   (total, "%.2f" % p["total"] if p["total"] is not None else "not found"))
        tk.Label(w, text=verdict, fg=GREEN if ok else RED, font=("Segoe UI", 10, "bold")).pack(anchor="w", padx=10, pady=6)
        if p["notes"]:
            tk.Label(w, text="\n".join(p["notes"][:6]), fg=ORANGE, justify="left").pack(anchor="w", padx=10)
        ttk.Label(w, text="Text found in the PDF (write the patterns from this):").pack(anchor="w", padx=10)
        txt = tk.Text(w, font=("Consolas", 9))
        txt.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        txt.insert("end", p["text"])

    def tpl_which(self):
        """Which template a PDF gets, and why (in the order the templates are checked)."""
        import re as _re
        from .parser import pdf_text
        path = filedialog.askopenfilename(title="Choose an invoice PDF", filetypes=[("PDF", "*.pdf")])
        if not path:
            return
        try:
            text = "\n".join(pdf_text(path))
            doc = visual.Doc(path) if any(t.get("kind") == "visual" for t in self.s["templates"]) else None
        except Exception as e:
            messagebox.showerror(APP_NAME, "Cannot read the PDF:\n%s" % e)
            return
        is_cn = bool(_re.search(r"credit\s*note", text, _re.I))
        rows, winner, fallback = [], None, None
        for t in self.s["templates"]:
            dt = (t.get("doc_type") or "auto").lower()
            if dt == "invoice" and is_cn:
                res = "skipped: Invoice template, the PDF says 'credit note'"
            elif t.get("kind") == "visual":
                ids = [r["key"] for r in t.get("fields", []) if r["type"] == "DOCUMENT IDENTIFIER" and r.get("key")]
                if not ids:
                    res = "no DOCUMENT IDENTIFIER: used only if nothing else fits"
                    fallback = fallback or t
                else:
                    found = [k for k in ids if visual.find_all(doc, k)]
                    miss = [k for k in ids if k not in found]
                    res = ("MATCH (found: %s)" % ", ".join(found)) if not miss else ("no: '%s' not on this PDF" % "', '".join(miss))
                    if not miss and winner is None:
                        winner = t
            else:
                m = (t.get("match") or "").strip()
                if not m:
                    res = "no 'recognise by' text: used only if nothing else fits"
                    fallback = fallback or t
                else:
                    ok = bool(_re.search(m, text, _re.I | _re.M))
                    res = "MATCH ('%s' found)" % m if ok else "no: '%s' not on this PDF" % m
                    if ok and winner is None:
                        winner = t
            rows.append((t, res))
        chosen = winner or fallback
        w = tk.Toplevel(self.root)
        w.title("Which template? - %s" % os.path.basename(path))
        w.geometry("900x420")
        tk.Label(w, text=("This PDF will use:  %s" % chosen["name"]) if chosen else "No template fits this PDF.",
                 fg=GREEN if chosen else RED, font=("Segoe UI", 12, "bold")).pack(anchor="w", padx=12, pady=(12, 2))
        tk.Label(w, text="Templates are checked from the top. A PDF saved in a template's Input sub-folder always uses "
                         "that template.%s" % ("  (This PDF has no text: it was read with OCR.)" if doc and doc.ocr else ""),
                 fg=MUTED).pack(anchor="w", padx=12)
        tree = ttk.Treeview(w, columns=("n", "t", "d", "f", "r"), show="headings")
        for c, h, wd in (("n", "#", 30), ("t", "Template", 220), ("d", "Document", 90), ("f", "Folder", 110), ("r", "Result", 420)):
            tree.heading(c, text=h)
            tree.column(c, width=wd, anchor="w")
        for i, (t, res) in enumerate(rows, 1):
            tree.insert("", "end", tags=("win",) if t is chosen else (), values=(
                i, t["name"], {"invoice": "Invoice", "credit": "Credit note"}.get((t.get("doc_type") or "auto").lower(), "Detect"),
                ("Input\\" + t["folder"]) if t.get("folder") else "", res))
        tree.tag_configure("win", foreground=GREEN)
        tree.pack(fill="both", expand=True, padx=12, pady=8)

    def tpl_preview(self):
        path = filedialog.askopenfilename(title="Choose an invoice PDF to preview the stamp", filetypes=[("PDF", "*.pdf")])
        if not path:
            return
        t = self._form_tpl()
        out = os.path.join(tempfile.gettempdir(), "BRV ETR stamp preview.pdf")
        info = {"sdc_id": self.s.get("sdc_id") or "KRACU0000000000", "invc_no": "PREVIEW", "rcpt_no": 0, "tot_rcpt_no": 0,
                "intrl_data": "PREVIEW-NOT-SIGNED-PREVIEW", "rcpt_sign": "PREVIEWNOTSIGNED", "credit": False,
                "when": datetime.now(), "url": "https://etims.kra.go.ke"}
        try:
            stamp_pdf(path, out, info, t["stamp"])
        except Exception as e:
            messagebox.showerror(APP_NAME, "Preview failed:\n%s" % e)
            return
        open_path(out)


def run(settings, engine, minimized=False):
    root = tk.Tk()
    try:
        here = getattr(sys, "_MEIPASS", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        ico = os.path.join(here, "assets", "brv_etr.ico")  # BRV mark
        if os.path.exists(ico):
            root.iconbitmap(ico)
    except Exception:
        pass
    App(root, settings, engine)
    if minimized:
        root.iconify()
    root.mainloop()
