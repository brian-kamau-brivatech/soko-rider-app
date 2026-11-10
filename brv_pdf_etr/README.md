# BRV PDF ETR (Windows)

Signs invoice PDFs with KRA eTIMS through a VSCU, the same way BRV POS does, and saves a stamped copy
(CU invoice number, receipt signature, internal data, KRA QR code).

```
Accounting software ──PDF──▶ C:\BRV ETR\Input ──▶ BRV PDF ETR ──▶ VSCU / KRA
                                                     │
                     C:\BRV ETR\Output ◀── signed and stamped PDF
                     C:\BRV ETR\Error  ◀── PDFs it could not sign + "REASON.txt"
                     C:\BRV ETR\Archive◀── originals after signing
```

## Install (BRV technician)
1. Download `BRV-PDF-ETR.exe` from the latest **BRV PDF ETR** release on GitHub, put it in `C:\BRV ETR\App`
   and double-click it. (SmartScreen: **More info → Run anyway**.)
2. First start: create the **admin password**. Only BRV knows it. The client sees only **Invoices** and
   **Reports**; **Items**, **Client templates** and **Settings** open with **Admin** (locks again after 15 min).
3. **Settings**: VSCU address, KRA PIN, branch, device serial → **Save and connect** (green = connected).
   Set the default KRA item class, exchange rates (`USD=129.00`), VAT-free words, tick *Open when Windows starts*.
4. **Licence...**: read the **machine code** (e.g. `BYD5-PAW4`) and make a licence with the BRV Licence Maker
   for the number of days paid. Paste the key → **Activate licence**. The client can paste renewals himself.
5. **Items**: add items or **Import Excel** (format: **Excel template**), then **Register at KRA**.
6. **Client templates**: one per invoice layout (below). Set the **Invoice currency** (KES, USD or INVOICE).

### Licences
- A key is for one computer and a number of days. 7 days before the end the app shows an orange warning;
  after the end it shows **NOT SIGNING** and PDFs wait in Input (nothing is lost). Paste a new key to continue.
- Turning the computer date back is detected.
- Keys are made only with **BRV Licence Maker** + BRV's private key file (`brv_licence_private_key.pem`).
  Keep that file off client computers. Every key made is logged in `licences.csv` next to the key file.

### Where the settings are
Settings, items and invoice records are in a hidden folder `%LOCALAPPDATA%\BRV\.etr` (encrypted settings
`cfg.dat`, records `data.db`). The settings file is encrypted for this computer only: a copy or a hand-edited
file is refused and signing stops until BRV sets the app up again.

### Currencies and document types
- KES invoices are sent as printed. USD/EUR/GBP invoices are converted to KES (KRA amounts are in KES) using the
  rate printed on the invoice (EXCHANGE RATE row) or the rate in Settings. The stamp shows the rate used.
- Credit notes are recognised by the template (CREDIT NOTE IDENTIFIER) and linked to the original invoice.
- Invoices tab filter: All / Invoices / Credit notes / KES / USD / Not signed. Reports: same filters.

## Reports
Reports tab: choose dates (Today, This week, This month, Last month), invoices/credit notes, currency.
Shows totals by tax group (A-E) and by currency; **Export Excel** (summary, daily, documents), **PDF**, **CSV**.

## Set up each client (Client templates → New: design on a PDF)
Every accounting program prints invoices differently, so each client gets a template, made by clicking
on one of their invoices:
1. Click **New: design on a PDF...** and choose a sample invoice of that client.
2. **Drag a box around a label** on the invoice, e.g. `INVOICE. No`, `CUST PIN`, `Invoice Total`.
   A row is added and the app guesses its TYPE; change it if needed. The value it reads shows in green.
3. Rows to add:
   - **DOCUMENT IDENTIFIER**: text found on every invoice of this client (e.g. their PIN or `Currency : KSH`).
   - **INVOICE NO**, **CUSTOMER TIN**, **CUSTOMER NAME** (no label? set VALUE IS = BOX and drag around the name).
   - **TOTAL AMOUNT**: always add it; everything is checked against it.
   - Either the **item columns** (LIST ITEM START, LIST ITEM END, COLUMN DESCRIPTION / QTY / PRICE / AMOUNT...)
   - or the **totals** (NET TAXABLE, VAT, ZERO RATED, EXEMPT, NON TAXABLE). Hotel folios with
     allowance/discount lines are signed from the totals. Each total has its KRA tax code and item name.
   - **SERVICE CHARGE** and **CATERING LEVY** are read so the total adds up, but are NOT sent to KRA
     (tick TO KRA only if a client must transmit one). KRA gets the effective total and its VAT.
   - Add the **VAT** row whenever the invoice prints a VAT amount: the lines must give the same VAT.
   - Credit notes: CREDIT NOTE IDENTIFIER and ORIGINAL INVOICE NO.
   - **Item table in one go**: click **Item columns...**: the headings found on the PDF are filled in (unused ones
     already marked with `:`); add or remove `:` and click OK. Example:
     `/No,TAX,ItemDescription,:Qty,:UnitPrice,:Tax,:DiscountRt,:DiscountAmt,Amount`
     (`:` before a heading = that column is on the invoice but NOT used; here only TAX, description and Amount are used).
     If Amount is not used, the line amount is Qty x UnitPrice - discount, and discounts go to KRA as discount.
   - **Document** (top bar): *Invoice* (never signs a PDF that says "credit note"), *Credit note* (every PDF of
     this template is a credit note; add ORIGINAL INVOICE NO) or *Detect* (CREDIT NOTE IDENTIFIER row).
4. The bottom line must show **✔ To KRA ... = invoice total**. Click **Save**.
5. In the Client templates tab you can still set the item classification, units, payment type and where
   the KRA box is stamped (Preview stamp... shows it). Templates are checked top to bottom.

## Different templates (one per client / software / document type)
- **Input sub-folder** (Client templates → template options): e.g. `Yiwak`. The client's software saves its PDFs
  in `C:\BRV ETR\Input\Yiwak` and they always use that template. No identifier needed, and two layouts that
  look alike can never be mixed up. Signed copies go to `Output\Yiwak`, problems to `Error\Yiwak`.
- PDFs saved directly in `Input` are matched by the templates' **DOCUMENT IDENTIFIER** text, top to bottom.
- **Which template?** (Client templates) shows for any PDF which template it gets and why.
- **Document**: Invoice / Credit note / Detect per template, so a client can have an invoice template and a
  credit note template (e.g. `Input\Yiwak` and `Input\Yiwak CN`).
- **Export template... / Import template...** copy a trained template to another computer (.brvtpl file).

## PDFs whose text is a picture (OCR add-on)
Some programs (e.g. printing through "Microsoft Print to PDF" from some systems) turn the text into shapes, and
scans are pictures: such PDFs have no text to read. Download **BRV-OCR-addon.zip** from the same release,
unzip it next to BRV-PDF-ETR.exe (a folder `BRV-OCR`). Settings shows "OCR add-on: installed". Then these PDFs are
read with OCR (2-5 seconds a page) and trained in the designer like any other. For OCR-read PDFs the TOTAL AMOUNT
row is required, so every amount is checked. Better still: ask the client to print to PDF so the text is kept.

## Where the KRA CU information is printed (designer → KRA box bar)
| Choice | Use it when |
|---|---|
| **Under a text (moves with it)** | Best for most invoices. Pick a text that is always just above the free space (e.g. `Invoice Total`, `END`). The box stays under it even when the invoice has more lines. |
| **Fixed spot on the page** | The layout never changes (pre-printed space for the KRA box). Drag the box there. |
| **After the last line** | Till rolls (80 mm). The page is made longer if needed. |
| **Auto** | Finds the first empty space (bottom right, bottom left, then upwards). |
| Corners | Bottom right / left / centre, top right / left with margins. |

Steps: open the template in the designer → choose the KRA box option → **Pick text** (drag around e.g.
`Invoice Total`) → **Move KRA box** and drag the gold box → **Preview real stamp** → **Save**.
Page: last (default), first or all. Look: **clean** (default) or **box** (framed). The clean block follows the KRA
TIS specification (6.23): `SCU INFORMATION`, `Date: dd/mm/yyyy Time: hh:mm:ss`, `CU ID`, `CU INVOICE NO: KRACU.../n`,
`Receipt Number: A/B NS` (NC for credit notes), internal data and receipt signature with a dash every 4 characters,
QR code, then TIS INFORMATION (this app's invoice number and date). The title can be changed (template options).
On till rolls the clean block goes under the last line.
A red "covers text" warning means the box would print over words: move it.

## VAT-free items (milk, bread, eggs...)
Every line sent to KRA gets a tax code: B 16%, E 8%, C zero rated, A exempt, D non-VAT. It comes from,
in this order:
1. the VAT column on the invoice (template "VAT column" list, e.g. `16%=B, 0%=C, Z=C, E=A`);
2. the **Items** list (by item code, then name) - add items there or import them from Excel;
3. **Settings → VAT-free items**, words in the description, e.g. `milk=C, bread=C, eggs=A`;
4. with "Lines with no code = AUTO", the VAT printed on the invoice: VAT 0.00 → all lines VAT-free
   (C or A as the template says); VAT = 16% of them → 16%.
If an invoice mixes VAT-free and 16% items that are not known yet, it is NOT signed: it goes to Error
with the item names, so nothing is ever sent with the wrong VAT. Add the words in Settings and drop the
PDF back in Input.

## Daily use
- The accounting software prints or saves the invoice PDF into the **Input** folder.
- Within a few seconds the signed PDF appears in **Output**. The **Invoices** tab lists everything.
- Printing the same PDF again does not create a new KRA invoice; you get the signed copy again.
- Credit notes: the original invoice must have been signed by this app first, and credit notes can never add up to
  more than the original invoice (KRA: an original transaction may be cancelled only once).
- A PDF that already carries KRA CU information (signed by another device) is refused, so no sale is sent twice.
- If the VSCU is off, invoices wait in Input and are sent automatically, keeping their numbers.
- Anything in **Error** has a `REASON.txt`. Fix it (usually the template) and drop the PDF in Input again.

## Notes
- Scanned (picture) PDFs cannot be read; print to PDF from the accounting program.
- Item lines with negative amounts are not sent; such invoices are signed from their totals.
- An invoice showing a different seller PIN (DOCUMENT TIN) than this app's PIN is refused.
- Only one copy can run at a time.

## Build
GitHub Actions (`.github/workflows/build_pdf_etr.yml`) runs the tests against a fake VSCU, builds the
exe with PyInstaller on Windows, self-tests the exe and attaches it to a release.
