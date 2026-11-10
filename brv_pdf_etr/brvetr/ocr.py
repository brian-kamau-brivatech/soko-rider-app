"""Reading PDFs that have no text (text drawn as shapes, scans) with OCR.

The OCR engine is large, so it is an optional add-on (BRV-OCR-addon.zip): a folder "BRV-OCR" with
brv_ocr.exe, next to BRV-PDF-ETR.exe or in %LOCALAPPDATA%\\BRV\\ocr. When Python has rapidocr installed
(development), it is used directly. Results are cached per file so a PDF is read only once.
"""
import hashlib
import json
import os
import subprocess
import sys

SCALE = 3.0  # render at 216 dpi: small print reads reliably
_cache = {}


def helper_path():
    if os.environ.get("BRV_OCR_HELPER") and os.path.isfile(os.environ["BRV_OCR_HELPER"]):
        return os.environ["BRV_OCR_HELPER"]
    names = ("brv_ocr.exe", "brv_ocr")
    here = os.path.dirname(sys.executable if getattr(sys, "frozen", False) else os.path.abspath(sys.argv[0] or "."))
    roots = [os.path.join(here, "BRV-OCR"), here]
    base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), ".local", "share")
    roots.append(os.path.join(base, "BRV", "ocr", "BRV-OCR"))
    roots.append(os.path.join(base, "BRV", "ocr"))
    for r in roots:
        for n in names:
            p = os.path.join(r, n)
            if os.path.isfile(p):
                return p
    return None


def in_process():
    if os.environ.get("BRV_OCR_HELPER"):
        return False  # tests: use the add-on program
    try:
        import rapidocr_onnxruntime  # noqa: F401
        return True
    except Exception:
        return False


def available():
    return in_process() or helper_path() is not None


def status_text():
    if in_process():
        return "OCR: built in"
    p = helper_path()
    return ("OCR add-on: installed (%s)" % p) if p else "OCR add-on: not installed (only needed for picture PDFs)"


def _key(path):
    st = os.stat(path)
    return hashlib.sha1(("%s|%s|%s" % (os.path.abspath(path), st.st_size, st.st_mtime)).encode()).hexdigest()


def split_words(text, x0, x1, top, bottom):
    """OCR gives phrases: cut them into words with x positions in proportion to the letters."""
    parts = text.split()
    if not parts:
        return []
    total = max(1, len(text))
    cw = (x1 - x0) / total
    out, pos = [], 0
    for p in parts:
        i = text.index(p, pos)
        out.append({"text": p, "x0": x0 + i * cw, "x1": x0 + (i + len(p)) * cw, "top": top, "bottom": bottom})
        pos = i + len(p)
    return out


def ocr_pdf(path, pages):
    """{page_index: [words]} in PDF points (origin top-left), for the pages asked."""
    pages = sorted(set(pages))
    if not pages:
        return {}
    k = _key(path)
    got = _cache.setdefault(k, {})
    todo = [p for p in pages if p not in got]
    if todo:
        if in_process():
            got.update(_run_local(path, todo))
        else:
            helper = helper_path()
            if not helper:
                raise RuntimeError("This PDF has no text (it is a picture). Install the BRV OCR add-on to read it, or "
                                   "print the invoice to PDF so that the text is kept.")
            r = subprocess.run([helper, path, ",".join(str(p) for p in todo)], capture_output=True, text=True,
                               timeout=300, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if r.returncode != 0:
                raise RuntimeError("OCR failed: %s" % (r.stderr or r.stdout)[-300:])
            data = json.loads(r.stdout)
            got.update({int(k_): v for k_, v in data.items()})
    return {p: got.get(p, []) for p in pages}


_engine = None


def _run_local(path, pages):
    global _engine
    import numpy as np
    import pypdfium2
    from rapidocr_onnxruntime import RapidOCR
    if _engine is None:
        _engine = RapidOCR()
    doc = pypdfium2.PdfDocument(path)
    out = {}
    for pi in pages:
        img = doc[pi].render(scale=SCALE).to_pil().convert("RGB")
        res, _ = _engine(np.array(img))
        words = []
        for box, text, conf in res or []:
            if conf < 0.5:
                continue
            xs = [p[0] / SCALE for p in box]
            ys = [p[1] / SCALE for p in box]
            words += split_words(text, min(xs), max(xs), min(ys), max(ys))
        out[pi] = words
    doc.close()
    return out


def main():
    """brv_ocr <pdf> <page,page,...>  -> JSON {page: [words]} on stdout (used by the main app)."""
    path = sys.argv[1]
    pages = [int(x) for x in sys.argv[2].split(",")] if len(sys.argv) > 2 else [0]
    print(json.dumps({str(k): v for k, v in _run_local(path, pages).items()}))


if __name__ == "__main__":
    main()
