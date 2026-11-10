"""BRV OCR add-on: reads PDFs whose text is a picture. Called by BRV PDF ETR (brv_ocr <pdf> <pages>)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from brvetr.ocr import main  # noqa: E402

if __name__ == "__main__":
    main()
