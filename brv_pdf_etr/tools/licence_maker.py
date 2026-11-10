"""BRV Licence Maker - FOR BRV ONLY. Makes BRV PDF ETR and BRV POS (Android) licence keys for a number of days,
and BRV POS technician keys (unlock the KRA/header settings or reset a forgotten technician PIN; 2 days, one device).

Needs BRV's private key file (brv_licence_private_key.pem). Keep that file safe and never give it to
clients: anyone with it can make licences. Every key made is written to licences.csv next to the key file.

Command line:
  licence_maker.py --key brv_licence_private_key.pem --machine BYD5-PAW4 --days 30 --customer "Ngulia"
  licence_maker.py --key brv_licence_private_key.pem --machine 7K2P-9QXA --days 365 --customer "Mama Duka" --product pos
  licence_maker.py --key brv_licence_private_key.pem --machine 7K2P-9QXA --tech     BRV POS technician key
  licence_maker.py --key brv_licence_private_key.pem --list              all licences, newest first
  licence_maker.py --key brv_licence_private_key.pem --list ngulia       only matching customer/machine/note
  licence_maker.py --key brv_licence_private_key.pem --list --active     only licences still running
  licence_maker.py --key brv_licence_private_key.pem --list --ending 14  running out within 14 days
"""
import argparse
import csv
import json
import os
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from brvetr import licence  # noqa: E402

CFG = os.path.join(os.path.expanduser("~"), ".brv_licence_maker.json")


def load_key(path):
    from cryptography.hazmat.primitives import serialization
    with open(path, "rb") as f:
        k = serialization.load_pem_private_key(f.read(), None)
    from cryptography.hazmat.primitives import serialization as S
    pub = k.public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw)
    if pub != licence.PUBLIC_KEY:
        raise ValueError("This private key does not belong to BRV PDF ETR (public key mismatch).")
    return k


def log_path(key_path):
    return os.path.join(os.path.dirname(os.path.abspath(key_path)), "licences.csv")


def next_serial(key_path):
    p = log_path(key_path)
    if not os.path.exists(p):
        return 1
    with open(p, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    return max([int(r.get("serial") or 0) for r in rows] + [0]) + 1


def all_licences(key_path, search="", active=False, ending=None):
    """Licences from licences.csv with days left and state, newest first."""
    p = log_path(key_path)
    if not os.path.exists(p):
        return []
    with open(p, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    today = date.today()
    out = []
    for r in rows:
        try:
            exp = date.fromisoformat(r["expires"])
        except (KeyError, ValueError):
            continue
        left = (exp - today).days
        r["days_left"] = left
        r["state"] = "EXPIRED" if left < 0 else ("ENDING" if left <= 7 else "ACTIVE")
        out.append(r)
    # a computer renewed later is shown as RENEWED on its older keys
    newest = {}
    for r in out:
        m = r["machine"]
        if m not in newest or r["expires"] > newest[m]["expires"]:
            newest[m] = r
    for r in out:
        if newest[r["machine"]] is not r and r["state"] != "EXPIRED":
            r["state"] = "REPLACED"
        elif newest[r["machine"]] is not r:
            r["state"] = "OLD"
    q = (search or "").lower()
    if q:
        out = [r for r in out if q in (r["customer"] + " " + r["machine"] + " " + r.get("note", "")).lower()]
    if active:
        out = [r for r in out if newest[r["machine"]] is r and r["days_left"] >= 0]
    if ending is not None:
        out = [r for r in out if newest[r["machine"]] is r and 0 <= r["days_left"] <= ending]
    out.sort(key=lambda r: int(r["serial"]), reverse=True)
    return out


def print_table(rows):
    if not rows:
        print("No licences found.")
        return
    print("%-4s %-10s %-10s %5s %-9s %-24s %-10s %s" % ("#", "Issued", "Expires", "Left", "State", "Customer",
                                                         "Machine", "Note"))
    print("-" * 100)
    for r in rows:
        print("%-4s %-10s %-10s %5s %-9s %-24s %-10s %s" % (r["serial"], r["issued"], r["expires"], r["days_left"],
                                                            r["state"], r["customer"][:24], r["machine"],
                                                            r.get("note", "")[:30]))
    act = sum(1 for r in rows if r["state"] in ("ACTIVE", "ENDING"))
    print("-" * 100)
    print("%d licence(s) shown, %d running now, %d ending within 7 days." % (
        len(rows), act, sum(1 for r in rows if r["state"] == "ENDING")))


PRODUCTS = {"PDF ETR": licence.VERSION_PDF_ETR, "BRV POS": licence.VERSION_POS}


def _machine(machine):
    machine = machine.strip().upper()
    if len(machine.replace("-", "")) != 8:
        raise ValueError("The machine / device code has 8 letters/digits, like BYD5-PAW4.")
    return machine


def issue(key_path, machine, days, customer, note="", product="PDF ETR"):
    k = load_key(key_path)
    machine = _machine(machine)
    if product not in PRODUCTS:
        raise ValueError("Product must be one of: %s" % ", ".join(PRODUCTS))
    if product == "BRV POS" and not note.startswith("[POS]"):
        note = ("[POS] " + note).strip()
    serial = next_serial(key_path)
    key, exp = licence.make(k, machine, int(days), serial, version=PRODUCTS[product])
    p = log_path(key_path)
    new = not os.path.exists(p)
    with open(p, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["serial", "issued", "expires", "days", "customer", "machine", "note", "key"])
        w.writerow([serial, date.today().isoformat(), exp.isoformat(), days, customer, machine, note, key])
    return key, exp, serial


def tech_key(key_path, machine, who=""):
    """BRV POS technician key: valid today and the next 2 days, for one device. Logged in tech_keys.csv
    (not in licences.csv, so it never shows as a licence)."""
    k = load_key(key_path)
    machine = _machine(machine)
    key, exp = licence.make(k, machine, 2, 0, version=licence.VERSION_TECH)
    p = os.path.join(os.path.dirname(os.path.abspath(key_path)), "tech_keys.csv")
    new = not os.path.exists(p)
    with open(p, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["made", "valid_until", "device", "who"])
        w.writerow([date.today().isoformat(), exp.isoformat(), machine, who])
    return key, exp


def gui():
    import tkinter as tk
    from tkinter import filedialog, messagebox, ttk
    cfg = {}
    try:
        with open(CFG) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        pass
    root = tk.Tk()
    root.title("BRV Licence Maker - BRV PDF ETR & BRV POS")
    root.geometry("780x580")
    root.configure(bg="#F4F6FA")
    head = tk.Frame(root, bg="#0A2348")
    head.pack(fill="x")
    tk.Label(head, text="BRV Licence Maker", fg="white", bg="#0A2348", font=("Segoe UI", 15, "bold")).pack(side="left", padx=14, pady=10)
    tk.Label(head, text="BRV PDF ETR / BRV POS licences by days  -  for BRV only", fg="#C38B2C", bg="#0A2348").pack(side="left")
    f = tk.Frame(root, bg="#F4F6FA")
    f.pack(fill="x", padx=16, pady=12)
    v = {k: tk.StringVar(value=cfg.get(k, d)) for k, d in
         (("key", ""), ("product", "PDF ETR"), ("customer", ""), ("machine", ""), ("days", "30"), ("note", ""))}
    rows = [("key", "Private key file"), ("product", "Product"), ("customer", "Customer / business"),
            ("machine", "Machine / device code"), ("days", "Days"), ("note", "Note (e.g. M-Pesa ref)")]
    for i, (k, label) in enumerate(rows):
        tk.Label(f, text=label, bg="#F4F6FA").grid(row=i, column=0, sticky="w", pady=4)
        if k == "product":
            ttk.Combobox(f, textvariable=v[k], values=list(PRODUCTS), width=12, state="readonly"
                         ).grid(row=i, column=1, sticky="w", padx=6)
        elif k == "days":
            ttk.Combobox(f, textvariable=v[k], values=["7", "14", "30", "60", "90", "180", "365", "730"], width=10
                         ).grid(row=i, column=1, sticky="w", padx=6)
        else:
            ttk.Entry(f, textvariable=v[k], width=60).grid(row=i, column=1, sticky="w", padx=6)
        if k == "key":
            ttk.Button(f, text="Browse", command=lambda: v["key"].set(
                filedialog.askopenfilename(filetypes=[("Key", "*.pem")]) or v["key"].get())).grid(row=i, column=2)
    out = tk.Text(root, height=7, font=("Consolas", 10), wrap="char")
    msg = tk.Label(root, text="", bg="#F4F6FA", fg="#0E8A55", font=("Segoe UI", 10, "bold"))

    def make():
        try:
            key, exp, serial = issue(v["key"].get(), v["machine"].get(), int(v["days"].get()), v["customer"].get(),
                                     v["note"].get(), v["product"].get())
        except Exception as e:
            messagebox.showerror("Licence Maker", str(e))
            return
        with open(CFG, "w") as fh:
            json.dump({"key": v["key"].get(), "days": v["days"].get(), "product": v["product"].get()}, fh)
        out.delete("1.0", "end")
        out.insert("1.0", key)
        msg.configure(text="Licence #%d for %s, %s days, ends %s. Saved in licences.csv" % (
            serial, v["machine"].get().upper(), v["days"].get(), exp.strftime("%d/%m/%Y")))
        if v["product"].get() == "BRV POS":
            text = ("BRV POS licence for %s (device %s), valid until %s:\n\n%s\n\nCopy this whole message, open BRV POS > "
                    "Licence > Paste > Activate licence." % (v["customer"].get(), v["machine"].get().upper(),
                                                             exp.strftime("%d/%m/%Y"), key))
        else:
            text = ("BRV PDF ETR licence for %s (computer %s), valid until %s:\n\n%s\n\nOpen BRV PDF ETR > Licence... > "
                    "paste the key > Activate licence." % (v["customer"].get(), v["machine"].get().upper(),
                                                             exp.strftime("%d/%m/%Y"), key))
        root.clipboard_clear()
        root.clipboard_append(text)
    def show_all():
        if not v["key"].get():
            messagebox.showwarning("Licence Maker", "Choose the private key file first.")
            return
        w = tk.Toplevel(root)
        w.title("All licences")
        w.geometry("1000x480")
        top = tk.Frame(w)
        top.pack(fill="x", padx=8, pady=6)
        tk.Label(top, text="Search:").pack(side="left")
        q = tk.StringVar()
        ttk.Entry(top, textvariable=q, width=30).pack(side="left", padx=6)
        only = tk.StringVar(value="All")
        ttk.Combobox(top, textvariable=only, values=["All", "Running", "Ending in 14 days"], width=18,
                     state="readonly").pack(side="left")
        info = tk.Label(top, text="")
        info.pack(side="right")
        cols = ("serial", "issued", "expires", "days_left", "state", "customer", "machine", "note")
        tree = ttk.Treeview(w, columns=cols, show="headings")
        for c, h, wd in zip(cols, ("#", "Issued", "Expires", "Days left", "State", "Customer", "Machine", "Note"),
                            (40, 90, 90, 70, 80, 250, 90, 200)):
            tree.heading(c, text=h)
            tree.column(c, width=wd)
        tree.pack(fill="both", expand=True, padx=8)
        for st, col in (("EXPIRED", "#B4232A"), ("ENDING", "#A95C00"), ("ACTIVE", "#0E8A55"), ("REPLACED", "#777777"),
                        ("OLD", "#999999")):
            tree.tag_configure(st, foreground=col)

        def fill(*_):
            o = only.get()
            rows = all_licences(v["key"].get(), q.get(), active=o == "Running",
                                ending=14 if o.startswith("Ending") else None)
            tree.delete(*tree.get_children())
            for r in rows:
                tree.insert("", "end", tags=(r["state"],), values=[r[c] for c in cols])
            info.configure(text="%d shown, %d running" % (len(rows), sum(1 for r in rows if r["state"] in ("ACTIVE", "ENDING"))))

        def copy_key(_e=None):
            sel = tree.selection()
            if sel:
                serial = tree.item(sel[0])["values"][0]
                for r in all_licences(v["key"].get()):
                    if str(r["serial"]) == str(serial):
                        root.clipboard_clear()
                        root.clipboard_append(r["key"])
                        info.configure(text="Key #%s copied" % serial)
        q.trace_add("write", fill)
        only.trace_add("write", fill)
        tree.bind("<Double-1>", copy_key)
        tk.Label(w, text="Double-click a licence to copy its key again.").pack(pady=4)
        fill()

    bar = tk.Frame(root, bg="#F4F6FA")
    bar.pack(pady=6)
    ttk.Button(bar, text="Make licence (copies a WhatsApp message)", command=make).pack(side="left", padx=4)
    ttk.Button(bar, text="Show all licences", command=show_all).pack(side="left", padx=4)

    def make_tech():
        try:
            key, exp = tech_key(v["key"].get(), v["machine"].get(), v["customer"].get())
        except Exception as e:
            messagebox.showerror("Licence Maker", str(e))
            return
        out.delete("1.0", "end")
        out.insert("1.0", key)
        msg.configure(text="Technician key for BRV POS device %s, valid until %s. Copied. FOR BRV STAFF ONLY." % (
            v["machine"].get().upper(), exp.strftime("%d/%m/%Y")))
        root.clipboard_clear()
        root.clipboard_append(key)
    ttk.Button(bar, text="BRV POS technician key", command=make_tech).pack(side="left", padx=4)
    msg.pack()
    out.pack(fill="x", padx=16, pady=8)
    tk.Label(root, text="Keep the private key file safe. Anyone who has it can make licences.", bg="#F4F6FA",
             fg="#B4232A").pack(side="bottom", pady=8)
    root.mainloop()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--key")
    ap.add_argument("--machine")
    ap.add_argument("--days", type=int)
    ap.add_argument("--customer", default="")
    ap.add_argument("--note", default="")
    ap.add_argument("--product", choices=["etr", "pos"], default="etr", help="etr = BRV PDF ETR (default), pos = BRV POS")
    ap.add_argument("--tech", action="store_true", help="BRV POS technician key for --machine (2 days)")
    ap.add_argument("--list", nargs="?", const="", default=None, metavar="SEARCH")
    ap.add_argument("--active", action="store_true")
    ap.add_argument("--ending", type=int)
    a = ap.parse_args()
    if a.key and a.list is not None:
        print_table(all_licences(a.key, a.list, a.active, a.ending))
    elif a.key and a.machine and a.tech:
        key, exp = tech_key(a.key, a.machine, a.customer)
        print("BRV POS technician key for %s, valid until %s (BRV staff only):\n%s" % (a.machine.upper(), exp.isoformat(), key))
    elif a.key and a.machine and a.days:
        key, exp, serial = issue(a.key, a.machine, a.days, a.customer, a.note,
                                 "BRV POS" if a.product == "pos" else "PDF ETR")
        print("Licence #%d for %s until %s:\n%s" % (serial, a.machine.upper(), exp.isoformat(), key))
    else:
        gui()


if __name__ == "__main__":
    main()
