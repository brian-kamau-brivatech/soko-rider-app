"""A PDF that is only a picture (like a scan or text printed as shapes), for the OCR add-on test."""
import io
import os
import sys

import pypdfium2
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tests.make_samples import detailed_style  # noqa: E402

out = sys.argv[1]
tmp = out + ".text.pdf"
detailed_style(tmp, "OCR-77")
img = pypdfium2.PdfDocument(tmp)[0].render(scale=3).to_pil().convert("RGB")
c = canvas.Canvas(out, pagesize=(595.27, 841.89))
c.drawImage(ImageReader(img), 0, 0, 595.27, 841.89)
c.save()
os.remove(tmp)
print(out)
