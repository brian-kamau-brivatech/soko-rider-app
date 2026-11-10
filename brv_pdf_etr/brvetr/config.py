"""Settings and client templates, saved as JSON in the app's data folder."""
import copy
import json
import os
import sys
import threading

from . import APP_NAME


def old_data_dir():
    if sys.platform.startswith("win"):
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, APP_NAME)


def data_dir():
    """Hidden folder for settings, records and samples (see secure.py)."""
    from .secure import hidden_dir
    return hidden_dir()


def default_root():
    if sys.platform.startswith("win"):
        return r"C:\BRV ETR"
    return os.path.join(os.path.expanduser("~"), "BRV ETR")


# A client template says how to read one layout of invoice and where to stamp it.
# Regexes are Python regular expressions, case-insensitive, run on the PDF text.
DEFAULT_TEMPLATE = {
    "name": "Generic invoice",
    # Text that identifies this client's PDFs (regex). Empty = used when no other template matches.
    "match": "",
    "invoice_no": r"(?:invoice|inv|bill)\s*(?:no\.?|number|#)\s*[:.\-]?\s*([A-Z0-9][A-Z0-9/\-]*)",
    "date": r"(?:invoice\s*)?date\s*[:.\-]?\s*(\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}|\d{4}-\d{2}-\d{2})",
    "customer_name": r"(?:bill\s*to|customer\s*name|customer|invoice\s*to|sold\s*to)\s*[:.\-]?[ \t]*(.*)",
    # Any KRA PIN on the invoice that is not the seller's own PIN.
    "customer_pin": r"\b([AP]\d{9}[A-Z])\b",
    "total": r"(?:grand\s*total|total\s*(?:amount|due|payable)?|amount\s*due)\s*(?:\(?k(?:sh|es)\)?)?\s*[:.\-]?\s*(?:k(?:sh|es)\.?\s*)?([\d,]+\.\d{2})",
    "credit_note": r"credit\s*note",
    "credit_note_no": r"credit\s*note\s*(?:no\.?|number|#)\s*[:.\-]?\s*([A-Z0-9][A-Z0-9/\-]*)",
    "original_invoice": r"(?:original|against|ref(?:erence)?)\s*(?:invoice)?\s*(?:no\.?|number|#)?\s*[:.\-]?\s*([A-Z0-9][A-Z0-9/\-]*)",
    # Item lines. Named groups: desc, qty, price, amount (needed), tax (optional VAT code or %).
    "line": r"^(?P<desc>[A-Za-z].*?)\s+(?P<qty>\d+(?:\.\d+)?)\s+(?:[A-Za-z]{1,4}\s+)?(?P<price>[\d,]+\.\d{2})\s+(?:(?P<tax>\d{1,2}(?:\.\d+)?%|[A-E])\s+)?(?P<amount>[\d,]+\.\d{2})$",
    "lines_start": r"(?:description|item|particulars|product)",
    "lines_stop": r"(?:sub\s*-?\s*total|total|vat\s*\d|amount\s*due)",
    "prices_include_vat": True,
    "default_tax": "B",
    "free_code": "C",  # VAT-free lines (no VAT printed): C zero-rated or A exempt
    "tax_map": {"16%": "B", "16": "B", "S": "B", "V": "B", "8%": "E", "0%": "C", "Z": "C", "E": "A", "EX": "A"},
    "item_class": "",
    "qty_unit": "U",
    "pkg_unit": "NT",
    "item_type": "2",
    "payment": "01",
    "refund_reason": "06",
    # style: clean = plain centred CU block like a KRA receipt (default); box = framed box
    "stamp": {"page": "last", "anchor": "auto", "x_mm": 10, "y_mm": 10, "width_mm": 75, "style": "clean",
              "anchor_text": "", "title": "SCU INFORMATION"},
    # Currency of these invoices: KES, USD, EUR, GBP... or INVOICE = read it from the CURRENCY row.
    "currency": "KES",
    # Document type of this template: auto = invoice unless the CREDIT NOTE IDENTIFIER is found;
    # invoice = always an invoice (never signs a PDF that says "credit note"); credit = always a credit note.
    "doc_type": "auto",
    # Input sub-folder for this template (e.g. "Yiwak"): PDFs put in Input\Yiwak always use this template.
    "folder": "",
}

DEFAULTS = {
    "vscu_url": "",
    "tin": "",
    "bhf_id": "00",
    "serial": "",
    "initialised": False,
    "taxpayer_name": "",
    "sdc_id": "",
    "mrc_no": "",
    "user_name": "BRV PDF ETR",
    "item_class": "",  # default KRA item classification code for new items
    "input_dir": os.path.join(default_root(), "Input"),
    "output_dir": os.path.join(default_root(), "Output"),
    "error_dir": os.path.join(default_root(), "Error"),
    "archive_dir": os.path.join(default_root(), "Archive"),
    "send_incl_vat": True,  # line prices sent VAT inclusive (same as BRV POS); taxable amount is always without VAT
    "output_suffix": "",  # e.g. "_signed"; empty keeps the same file name
    "poll_seconds": 3,
    "auto_start": True,
    # Words in item descriptions and their KRA code, for invoices that do not print a VAT code per line.
    "tax_rules": "",
    "templates": [copy.deepcopy(DEFAULT_TEMPLATE)],
    # Exchange rates to KES for foreign-currency invoices (used when the invoice does not print a rate).
    "rates": "USD=129.00, EUR=140.00, GBP=165.00",
    "rates_date": "",
    "admin_pw": "",       # hash; set at first start
    "licence": "",
    "last_seen": "",      # newest date seen, to notice a clock turned back
}


class Settings:
    """Saved encrypted in the hidden data folder (cfg.dat). A path ending in .json = plain file (tests)."""
    _lock = threading.Lock()

    def __init__(self, path=None):
        self.path = path or os.path.join(data_dir(), "cfg.dat")
        self.plain = self.path.endswith(".json")
        self.tampered = False
        self.data = copy.deepcopy(DEFAULTS)
        self.load()

    def _read(self):
        if self.plain:
            if not os.path.exists(self.path):
                return None
            with open(self.path, encoding="utf-8") as f:
                return json.load(f)
        from . import secure
        try:
            return secure.load(self.path)
        except secure.Tampered:
            try:
                got = secure.load(self.path + ".bak")
            except secure.Tampered:
                got = None
            if got is None:
                self.tampered = True
            return got

    def load(self):
        self.data = copy.deepcopy(DEFAULTS)
        saved = None
        try:
            saved = self._read()
        except (OSError, ValueError):
            saved = None
        if saved is None and not self.plain and not self.tampered:
            # First start of this version: bring the old readable settings in, then remove them.
            old = os.path.join(old_data_dir(), "settings.json")
            if os.path.exists(old):
                try:
                    with open(old, encoding="utf-8") as f:
                        saved = json.load(f)
                    self.data.update(saved)
                    self.save()
                    os.remove(old)
                except (OSError, ValueError):
                    saved = None
        if saved:
            self.data.update(saved)
        # templates saved before a new option existed get the default value
        tpls = []
        for t in self.data.get("templates") or []:
            full = copy.deepcopy(DEFAULT_TEMPLATE)
            full.update(t)
            full["stamp"] = {**DEFAULT_TEMPLATE["stamp"], **(t.get("stamp") or {})}
            tpls.append(full)
        self.data["templates"] = tpls or [copy.deepcopy(DEFAULT_TEMPLATE)]

    def save(self):
        with self._lock:
            if self.plain:
                tmp = self.path + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(self.data, f, indent=2)
                os.replace(tmp, self.path)
            else:
                from . import secure
                secure.save(self.path, self.data)
            self.tampered = False

    def rates(self):
        """{'USD': 129.0, ...}"""
        out = {"KES": 1.0}
        for part in (self.data.get("rates") or "").replace(";", ",").split(","):
            if "=" in part:
                c, v = part.split("=", 1)
                try:
                    out[c.strip().upper()] = float(v.strip().replace(",", ""))
                except ValueError:
                    pass
        return out

    def __getitem__(self, k):
        return self.data[k]

    def __setitem__(self, k, v):
        self.data[k] = v

    def get(self, k, d=None):
        return self.data.get(k, d)

    @property
    def root(self):
        return (self.data.get("vscu_url") or "").strip().rstrip("/")

    @property
    def ready(self):
        return bool(self.root and self.data.get("tin") and self.data.get("initialised"))

    def folders(self):
        return [self.data[k] for k in ("input_dir", "output_dir", "error_dir", "archive_dir")]

    def make_folders(self):
        for d in self.folders():
            os.makedirs(d, exist_ok=True)
        for t in self.data.get("templates") or []:
            sub = (t.get("folder") or "").strip()
            if sub:
                os.makedirs(os.path.join(self.data["input_dir"], sub), exist_ok=True)
