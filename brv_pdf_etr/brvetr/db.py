"""Local records: every invoice handled, items registered at KRA, VSCU call log."""
import json
import os
import re
import sqlite3
import threading

from .config import data_dir, old_data_dir

# Columns added after the first version (added to old databases on start).
UPGRADES = [
    ("invoices", "currency", "TEXT DEFAULT 'KES'"),
    ("invoices", "rate", "REAL DEFAULT 1"),
    ("invoices", "tot_amt_fc", "REAL"),
    ("invoices", "excluded", "REAL DEFAULT 0"),
    ("items", "sku", "TEXT DEFAULT ''"),
    ("items", "source", "TEXT DEFAULT 'auto'"),
    ("items", "origin", "TEXT DEFAULT 'KE'"),
    ("items", "updated_at", "TEXT"),
]

SCHEMA = """
CREATE TABLE IF NOT EXISTS invoices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_name TEXT, file_hash TEXT UNIQUE, template TEXT,
    trd_invc_no TEXT, invc_no INTEGER, kind TEXT DEFAULT 'S', org_invc_no INTEGER DEFAULT 0,
    cust_nm TEXT, cust_tin TEXT, tot_taxbl REAL, tot_tax REAL, tot_amt REAL, item_cnt INTEGER,
    status TEXT,               -- signed | waiting | failed
    error TEXT DEFAULT '',
    payload TEXT, response TEXT,
    rcpt_no INTEGER, tot_rcpt_no INTEGER, intrl_data TEXT, rcpt_sign TEXT, sdc_id TEXT, mrc_no TEXT,
    sdc_date TEXT, signed_at TEXT, created_at TEXT, input_path TEXT, output_path TEXT
);
CREATE INDEX IF NOT EXISTS ix_inv_trd ON invoices(trd_invc_no);
CREATE TABLE IF NOT EXISTS items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    key TEXT UNIQUE, name TEXT, item_cd TEXT, cls_cd TEXT, tax TEXT, qty_unit TEXT, pkg_unit TEXT,
    item_type TEXT, price REAL, registered INTEGER DEFAULT 0, reg_error TEXT DEFAULT ''
);
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT DEFAULT CURRENT_TIMESTAMP,
    path TEXT, request TEXT, response TEXT, ok INTEGER, code TEXT, msg TEXT, ms INTEGER
);
"""


def item_key(name):
    return re.sub(r"\s+", " ", (name or "").strip().lower())


class Db:
    def __init__(self, path=None):
        if not path:
            path = os.path.join(data_dir(), "data.db")
            old = os.path.join(old_data_dir(), "brv_pdf_etr.db")
            if not os.path.exists(path) and os.path.exists(old):
                for ext in ("", "-wal", "-shm"):
                    try:
                        os.replace(old + ext, path + ext)
                    except OSError:
                        pass
        self.path = path
        self.lock = threading.RLock()
        self.con = sqlite3.connect(self.path, check_same_thread=False, isolation_level=None)
        self.con.row_factory = sqlite3.Row
        self.con.execute("PRAGMA journal_mode=WAL")
        self.con.executescript(SCHEMA)
        for table, col, decl in UPGRADES:
            have = {r[1] for r in self.con.execute("PRAGMA table_info(%s)" % table)}
            if col not in have:
                self.con.execute("ALTER TABLE %s ADD COLUMN %s %s" % (table, col, decl))
        self.con.execute("CREATE INDEX IF NOT EXISTS ix_item_sku ON items(sku)")

    # -- key/value
    def get(self, k, d=None):
        with self.lock:
            r = self.con.execute("SELECT v FROM kv WHERE k=?", (k,)).fetchone()
        return r["v"] if r else d

    def set(self, k, v):
        with self.lock:
            self.con.execute("INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, str(v)))

    # -- invoice numbers (KRA invcNo): never reused, never goes backwards
    def next_invoice_no(self):
        return int(self.get("next_invc_no", "1"))

    def set_next_invoice_no(self, n):
        with self.lock:
            if int(n) > self.next_invoice_no() or self.get("next_invc_no") is None:
                self.set("next_invc_no", int(n))

    def force_next_invoice_no(self, n):
        self.set("next_invc_no", int(n))

    # -- invoices
    def insert(self, table, row):
        cols = ",".join(row)
        q = ",".join("?" * len(row))
        with self.lock:
            cur = self.con.execute("INSERT INTO %s (%s) VALUES (%s)" % (table, cols, q), list(row.values()))
            return cur.lastrowid

    def update(self, table, rid, row):
        sets = ",".join("%s=?" % k for k in row)
        with self.lock:
            self.con.execute("UPDATE %s SET %s WHERE id=?" % (table, sets), list(row.values()) + [rid])

    def invoice(self, rid):
        with self.lock:
            return self.con.execute("SELECT * FROM invoices WHERE id=?", (rid,)).fetchone()

    def by_hash(self, h):
        with self.lock:
            return self.con.execute("SELECT * FROM invoices WHERE file_hash=?", (h,)).fetchone()

    def signed_by_trd(self, trd):
        with self.lock:
            return self.con.execute("SELECT * FROM invoices WHERE trd_invc_no=? AND status='signed' AND kind='S' "
                                    "ORDER BY id DESC LIMIT 1", (trd,)).fetchone()

    def waiting(self):
        with self.lock:
            return self.con.execute("SELECT * FROM invoices WHERE status='waiting' ORDER BY id").fetchall()

    def recent(self, limit=500, search=""):
        with self.lock:
            if search:
                like = "%%%s%%" % search
                return self.con.execute(
                    "SELECT * FROM invoices WHERE file_name LIKE ? OR trd_invc_no LIKE ? OR cust_nm LIKE ? "
                    "OR CAST(invc_no AS TEXT) LIKE ? ORDER BY id DESC LIMIT ?",
                    (like, like, like, like, limit)).fetchall()
            return self.con.execute("SELECT * FROM invoices ORDER BY id DESC LIMIT ?", (limit,)).fetchall()

    def delete(self, rid):
        with self.lock:
            self.con.execute("DELETE FROM invoices WHERE id=?", (rid,))

    # -- items
    def item(self, name):
        with self.lock:
            return self.con.execute("SELECT * FROM items WHERE key=?", (item_key(name),)).fetchone()

    def item_by_sku(self, sku):
        if not (sku or "").strip():
            return None
        with self.lock:
            return self.con.execute("SELECT * FROM items WHERE lower(sku)=lower(?)", (sku.strip(),)).fetchone()

    def items(self, search=""):
        with self.lock:
            if search:
                like = "%%%s%%" % search
                return self.con.execute("SELECT * FROM items WHERE name LIKE ? OR sku LIKE ? OR item_cd LIKE ? "
                                        "ORDER BY name", (like, like, like)).fetchall()
            return self.con.execute("SELECT * FROM items ORDER BY name").fetchall()

    def item_by_id(self, iid):
        with self.lock:
            return self.con.execute("SELECT * FROM items WHERE id=?", (iid,)).fetchone()

    def delete_item(self, iid):
        with self.lock:
            self.con.execute("DELETE FROM items WHERE id=?", (iid,))

    def signed_between(self, d_from, d_to):
        """Signed invoices and credit notes with signed_at between two ISO dates (inclusive)."""
        with self.lock:
            return self.con.execute(
                "SELECT * FROM invoices WHERE status='signed' AND substr(signed_at,1,10) BETWEEN ? AND ? "
                "ORDER BY signed_at, id", (d_from, d_to)).fetchall()

    def next_item_seq(self):
        n = int(self.get("item_seq", "0")) + 1
        self.set("item_seq", n)
        return n

    # -- call log
    def log_call(self, path, payload, response, ok, code, msg, ms):
        self.insert("calls", {"path": path, "request": json.dumps(payload), "response": json.dumps(response),
                              "ok": 1 if ok else 0, "code": code, "msg": msg, "ms": ms})
