"""Item register: items with their KRA tax group, kept here and registered at KRA (items/saveItems).

Bulk upload uses an Excel file (BRV-PDF-ETR-items.xlsx format, see write_template).
When an invoice line is signed, its item is found by item code (if the invoice has a code column), then by
name. The item's tax group is used when the invoice does not print a VAT code for the line.
"""
from datetime import datetime

from . import kra
from .db import item_key

TAX_GROUPS = {"A": "A - Exempt (0%)", "B": "B - Standard 16%", "C": "C - Zero rated (0%)",
              "D": "D - Non-VAT", "E": "E - Reduced 8%"}
ITEM_TYPES = {"1": "1 - Raw material", "2": "2 - Finished product", "3": "3 - Service"}
QTY_UNITS = ["U", "KG", "GRM", "LTR", "ML", "MTR", "CMT", "M2", "M3", "BX", "BG", "CA", "CT", "DZ", "PA", "PR",
             "SET", "TN", "NO", "RL", "BL", "TU"]
PKG_UNITS = ["NT", "BG", "BX", "CT", "BO", "BL", "CA", "CR", "DR", "PK", "RL", "SA", "TU"]

# Excel columns: (heading, field, required, note)
COLUMNS = [
    ("Item Code", "sku", False, "Your own code / SKU as printed on invoices (optional)"),
    ("Item Name", "name", True, "Name as printed on invoices"),
    ("Tax Group", "tax", True, "A exempt, B 16%, C zero rated, D non-VAT, E 8%"),
    ("KRA Item Class Code", "cls_cd", False, "e.g. 5020230500 (empty = default in Settings)"),
    ("Quantity Unit", "qty_unit", False, "U pieces, KG, LTR... (empty = U)"),
    ("Packaging Unit", "pkg_unit", False, "NT net, BG bag, BX box... (empty = NT)"),
    ("Item Type", "item_type", False, "1 raw material, 2 finished product, 3 service (empty = 2)"),
    ("Unit Price incl VAT", "price", False, "Default price (optional)"),
    ("Country of Origin", "origin", False, "2 letters, e.g. KE (empty = KE)"),
]
EXPORT_EXTRA = [("KRA Item Code", "item_cd"), ("Registered at KRA", "registered"), ("KRA message", "reg_error")]


def clean(row, default_class=""):
    """Validate one item (dict of fields). Returns (item, errors)."""
    errs = []
    it = {k: ("" if row.get(k) is None else str(row.get(k)).strip()) for _, k, _, _ in COLUMNS}
    if not it["name"]:
        errs.append("Item Name is empty")
    t = it["tax"].upper()[:1]
    if t not in TAX_GROUPS:
        errs.append("Tax Group must be A, B, C, D or E (got '%s')" % it["tax"])
    it["tax"] = t
    it["cls_cd"] = it["cls_cd"].replace(".0", "") if it["cls_cd"].endswith(".0") else it["cls_cd"]
    it["cls_cd"] = it["cls_cd"] or default_class
    it["qty_unit"] = (it["qty_unit"] or "U").upper()
    it["pkg_unit"] = (it["pkg_unit"] or "NT").upper()
    it["item_type"] = (it["item_type"] or "2")[:1]
    if it["item_type"] not in ITEM_TYPES:
        errs.append("Item Type must be 1, 2 or 3")
    it["origin"] = (it["origin"] or "KE").upper()[:2]
    try:
        it["price"] = kra.r2(float(str(it["price"]).replace(",", ""))) if it["price"] else 0.0
    except ValueError:
        errs.append("Unit Price is not a number")
        it["price"] = 0.0
    if it["sku"].endswith(".0") and it["sku"][:-2].isdigit():
        it["sku"] = it["sku"][:-2]
    return it, errs


def upsert(db, it, source="manual"):
    """Add or update an item (found by item code, then name). Returns (id, changed_for_kra)."""
    row = db.item_by_sku(it.get("sku")) or db.item(it["name"])
    now = datetime.now().isoformat(timespec="seconds")
    fields = {"name": it["name"][:200], "sku": it.get("sku") or "", "tax": it["tax"], "cls_cd": it["cls_cd"],
              "qty_unit": it["qty_unit"], "pkg_unit": it["pkg_unit"], "item_type": it["item_type"],
              "price": it["price"], "origin": it.get("origin") or "KE", "source": source, "updated_at": now}
    if row:
        kra_fields = ("name", "tax", "cls_cd", "qty_unit", "pkg_unit", "item_type", "origin")
        changed = any(str(row[k] or "") != str(fields[k] or "") for k in kra_fields if k in row.keys())
        upd = dict(fields, key=item_key(it["name"]))
        if changed:
            upd["registered"] = 0
            upd["reg_error"] = ""
        # the KRA item code never changes once given (KRA updates the item under the same code)
        clash = db.item(it["name"])
        if clash and clash["id"] != row["id"]:
            upd.pop("key")
        db.update("items", row["id"], upd)
        return row["id"], changed
    seq = db.next_item_seq()
    fields.update({"key": item_key(it["name"]), "registered": 0, "reg_error": "",
                   "item_cd": kra.make_item_code(fields["origin"], fields["item_type"], fields["pkg_unit"],
                                                 fields["qty_unit"], seq)})
    return db.insert("items", fields), True


def find(db, desc, code=""):
    return db.item_by_sku(code) or (db.item(desc) if desc else None)


# ---------------------------------------------------------------------------- Excel
def _style_header(ws, ncols):
    from openpyxl.styles import Alignment, Font, PatternFill
    navy = PatternFill("solid", fgColor="0A2348")
    for c in range(1, ncols + 1):
        cell = ws.cell(row=1, column=c)
        cell.fill = navy
        cell.font = Font(bold=True, color="FFFFFF")
        cell.alignment = Alignment(vertical="center", wrap_text=True)
    ws.row_dimensions[1].height = 30
    ws.freeze_panes = "A2"


def _help_sheet(wb):
    from openpyxl.styles import Font
    hs = wb.create_sheet("Help")
    hs["A1"] = "BRV PDF ETR - item list for bulk upload"
    hs["A1"].font = Font(bold=True, size=14, color="0A2348")
    hs["A2"] = "Fill the Items sheet, one item per row from row 2. Columns marked * are required. Do not rename the headings."
    r = 4
    for head, _f, req, note in COLUMNS:
        hs.cell(row=r, column=1, value=head + (" *" if req else "")).font = Font(bold=True)
        hs.cell(row=r, column=2, value=note)
        r += 1
    r += 1
    hs.cell(row=r, column=1, value="Tax groups").font = Font(bold=True, color="C38B2C")
    for k, v in TAX_GROUPS.items():
        r += 1
        hs.cell(row=r, column=1, value=k)
        hs.cell(row=r, column=2, value=v)
    r += 2
    hs.cell(row=r, column=1, value="Item types").font = Font(bold=True, color="C38B2C")
    for k, v in ITEM_TYPES.items():
        r += 1
        hs.cell(row=r, column=1, value=k)
        hs.cell(row=r, column=2, value=v)
    r += 2
    hs.cell(row=r, column=1, value="Quantity units").font = Font(bold=True, color="C38B2C")
    hs.cell(row=r, column=2, value=", ".join(QTY_UNITS))
    r += 1
    hs.cell(row=r, column=1, value="Packaging units").font = Font(bold=True, color="C38B2C")
    hs.cell(row=r, column=2, value=", ".join(PKG_UNITS))
    hs.column_dimensions["A"].width = 26
    hs.column_dimensions["B"].width = 90


def _validation(ws, col_letter, values, rows=5000):
    from openpyxl.worksheet.datavalidation import DataValidation
    dv = DataValidation(type="list", formula1='"%s"' % ",".join(values), allow_blank=True)
    dv.error = "Choose from the list"
    ws.add_data_validation(dv)
    dv.add("%s2:%s%d" % (col_letter, col_letter, rows))


def write_template(path, examples=True):
    from openpyxl import Workbook
    wb = Workbook()
    ws = wb.active
    ws.title = "Items"
    for c, (head, _f, req, _n) in enumerate(COLUMNS, 1):
        ws.cell(row=1, column=c, value=head + (" *" if req else ""))
        ws.column_dimensions[ws.cell(row=1, column=c).column_letter].width = 34 if c == 2 else 18
    _style_header(ws, len(COLUMNS))
    if examples:
        for r, ex in enumerate([
                ("MLK500", "Fresh milk 500ml", "C", "5020230500", "U", "NT", "2", 60, "KE"),
                ("SOAP800", "Bar soap 800g", "B", "5020230500", "U", "NT", "2", 232, "KE"),
                ("EGG30", "Eggs tray 30", "A", "5020230500", "U", "NT", "2", 450, "KE"),
                ("SRV01", "Delivery service", "B", "", "U", "NT", "3", 500, "KE")], 2):
            for c, v in enumerate(ex, 1):
                ws.cell(row=r, column=c, value=v)
    _validation(ws, "C", list(TAX_GROUPS))
    _validation(ws, "G", list(ITEM_TYPES))
    _help_sheet(wb)
    wb.save(path)


def export(path, rows):
    from openpyxl import Workbook
    wb = Workbook()
    ws = wb.active
    ws.title = "Items"
    heads = [h for h, *_ in COLUMNS] + [h for h, _ in EXPORT_EXTRA]
    for c, h in enumerate(heads, 1):
        ws.cell(row=1, column=c, value=h)
        ws.column_dimensions[ws.cell(row=1, column=c).column_letter].width = 34 if c == 2 else 18
    _style_header(ws, len(heads))
    for r, it in enumerate(rows, 2):
        vals = [it[f] for _, f, *_ in COLUMNS] + [it["item_cd"], "Yes" if it["registered"] else "No", it["reg_error"]]
        for c, v in enumerate(vals, 1):
            ws.cell(row=r, column=c, value=v)
    _validation(ws, "C", list(TAX_GROUPS))
    _help_sheet(wb)
    wb.save(path)


def read_file(path, default_class=""):
    """Items from an Excel (.xlsx) or CSV file. Returns (items, errors) - errors as 'Row 5: ...'."""
    rows = []
    if path.lower().endswith(".csv"):
        import csv
        with open(path, newline="", encoding="utf-8-sig") as f:
            data = list(csv.reader(f))
    else:
        from openpyxl import load_workbook
        wb = load_workbook(path, read_only=True, data_only=True)
        ws = wb["Items"] if "Items" in wb.sheetnames else wb.worksheets[0]
        data = [list(r) for r in ws.iter_rows(values_only=True)]
    if not data:
        return [], ["The file is empty."]
    heads = [str(h or "").replace("*", "").strip().lower() for h in data[0]]
    idx = {}
    for head, field, req, _n in COLUMNS:
        if head.lower() in heads:
            idx[field] = heads.index(head.lower())
        elif req:
            return [], ["The column '%s' is missing. Use the Excel template." % head]
    errors = []
    seen = set()
    for n, r in enumerate(data[1:], 2):
        if not any(v not in (None, "") for v in r):
            continue
        raw = {f: (r[i] if i < len(r) else None) for f, i in idx.items()}
        it, errs = clean(raw, default_class)
        k = item_key(it["name"])
        if k in seen:
            errs.append("'%s' appears twice in the file" % it["name"])
        seen.add(k)
        if errs:
            errors.append("Row %d: %s" % (n, "; ".join(errs)))
        else:
            rows.append(it)
    return rows, errors
