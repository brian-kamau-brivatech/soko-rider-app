"""BRV PDF ETR - signs invoice PDFs with KRA eTIMS (VSCU) and stamps them."""
import socket
import sys

from brvetr import APP_NAME
from brvetr.config import Settings
from brvetr.db import Db
from brvetr.engine import Engine

LOCK_PORT = 47653  # only one copy may run, or an invoice could be signed twice


def single_instance():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", LOCK_PORT))
        s.listen(1)
        return s
    except OSError:
        return None


def selftest(out_dir):
    """Used by the build: proves the packaged exe can read, stamp and save a PDF."""
    import datetime
    import os
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas
    from brvetr import kra, parser, stamp
    from brvetr.config import DEFAULT_TEMPLATE
    os.makedirs(out_dir, exist_ok=True)
    src = os.path.join(out_dir, "selftest.pdf")
    c = canvas.Canvas(src, pagesize=A4)
    for i, t in enumerate(["INVOICE", "Invoice #: 77", "Bill To: Test Customer", "Description Qty Rate Amount",
                           "Cement 50kg bag 2 850.00 1,700.00", "Total KES 1,700.00"]):
        c.drawString(40, 780 - i * 16, t)
    c.save()
    got = parser.parse(src, [DEFAULT_TEMPLATE])
    assert got["invoice_no"] == "77" and len(got["lines"]) == 1 and got["total"] == 1700.0, got
    info = {"sdc_id": "KRACU0000000001", "invc_no": 1, "rcpt_no": 1, "tot_rcpt_no": 1, "intrl_data": "A" * 26,
            "rcpt_sign": "B" * 16, "when": datetime.datetime.now(), "credit": False,
            "url": kra.receipt_url("P000000000A", "00", "B" * 16)}
    dst = os.path.join(out_dir, "selftest_signed.pdf")
    stamp.stamp_pdf(src, dst, info, DEFAULT_TEMPLATE["stamp"])
    assert "CU INFORMATION" in "".join(parser.pdf_text(dst))
    import tkinter  # noqa: F401  (the window toolkit is packed)
    import pypdfium2
    from PIL import ImageTk  # noqa: F401  (designer preview)
    from brvetr import designer, visual  # noqa: F401
    assert pypdfium2.PdfDocument(dst)[0].render(scale=1).to_pil().width > 100
    assert visual.Doc(dst).pages[0]["lines"]
    # hidden encrypted settings, licence check, Excel and report export
    from brvetr import items, licence, reports, secure
    secure.save(os.path.join(out_dir, "t.dat"), {"a": 1})
    assert secure.load(os.path.join(out_dir, "t.dat")) == {"a": 1}
    assert licence.read("AAAA")[0] is None and secure.machine_code()
    items.write_template(os.path.join(out_dir, "items.xlsx"))
    got_items, errs = items.read_file(os.path.join(out_dir, "items.xlsx"), "5020230500")
    assert len(got_items) == 4 and not errs, errs
    reports.export_xlsx(os.path.join(out_dir, "r.xlsx"), [], "2026-01-01", "2026-01-31", "Test", "All")
    reports.export_pdf(os.path.join(out_dir, "r.pdf"), [], "2026-01-01", "2026-01-31", "Test", "All")
    assert os.path.exists(reports.asset("brv_logo.png"))
    # pictures in windows (logo, designer preview) need PIL's Tk bridge packed in the exe
    import tkinter as tk
    from brvetr.gui_more import logo_image
    r = tk.Tk()
    r.withdraw()
    assert logo_image("brv_mark.png", 40) is not None, "logo/preview images do not work"
    r.destroy()
    with open(os.path.join(out_dir, "selftest_ok.txt"), "w") as f:
        f.write("OK")


def main():
    if "--selftest" in sys.argv:
        selftest(sys.argv[sys.argv.index("--selftest") + 1])
        return
    lock = single_instance()
    if lock is None:
        try:
            import tkinter
            from tkinter import messagebox
            r = tkinter.Tk()
            r.withdraw()
            messagebox.showinfo(APP_NAME, "BRV PDF ETR is already running (look in the taskbar).")
        except Exception:
            print("Already running")
        return
    settings = Settings()
    engine = Engine(settings, Db())
    from brvetr.gui import run
    run(settings, engine, minimized="--minimized" in sys.argv)


if __name__ == "__main__":
    main()
