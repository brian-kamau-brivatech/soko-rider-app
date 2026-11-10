# BRV POS (Android) – generic edition for any client

KRA eTIMS point of sale for Android handhelds. Every sale is signed through the client's VSCU and the KRA
receipt is printed on the built-in printer, a paired Bluetooth printer or through Android printing.
Nothing is client-specific in the app: the BRV technician enters the KRA device and the receipt header on site.

```
Handheld (BRV POS) ──sale──▶ VSCU (http://IP:8088) ──▶ KRA eTIMS
        │
        └── receipt: header, items, VAT A–E, SCU information, KRA QR code
```

## Get the app
GitHub → **Releases** → newest **BRV POS v1.0.x** → download `app-release.apk` → copy it to the handheld → open it →
allow "Install unknown apps" → **Install**. Updates: install the new APK over the old one (never uninstall:
uninstalling deletes the sales on the device).

## Set up a new client (BRV technician, about 10 minutes)
Have ready: VSCU address, client KRA PIN, branch ID, device serial (exactly as on the eTIMS portal), the
receipt header details, and the logo (a photo on the handheld).

1. **Sign in**: username `admin`, password `Dev@96`. The app asks the shop to choose a new admin password.
2. **Unlock**: the Set up screen opens. Tap **Unlock** → **Create the technician PIN** (BRV only, at least 4
   characters, the same PIN for all your clients if you like). Unlocking lasts 15 minutes.
3. **VSCU connection**: VSCU address, e.g. `http://178.128.254.30:8088` → **Test connection** (green).
4. **Device**: KRA PIN, branch ID (`00` head office), device serial → **Connect device**. KRA's taxpayer
   name, branch and last invoice number are loaded; the next invoice number continues from KRA's.
5. **Receipt header**: logo, business name, address, phone, email, top message, bottom message.
6. **Printing**: paper width (58 or 80 mm) → **Printer** → pick the printer → **Test print**.
   - Built-in printer handhelds (Sunmi, Nyx/iMin-type, "recieptservice" models): found automatically.
   - Bluetooth printer: switch it on, pair it in Android **Settings → Bluetooth** (PIN 0000 or 1234), allow
     "Nearby devices" when BRV POS asks, then pick **Bluetooth: <name>** under Printer.
   - Anything else: **Android print screen**.
7. **Save settings**. Settings → **Licence** → read the **device code** (e.g. `7K2P-9QXA`) → make the licence
   (below) → paste → **Activate licence**.
8. **Items**: **New item** for each product (name, price incl. VAT, tax A–E, KRA class), or **⋮ → Import items
   registered at KRA** if the client's items are already at KRA. Items are registered at KRA automatically.
9. **Users**: add the cashiers (cashiers sell, reprint and see reports; only admins add items, manage users and open Settings).
10. Make one small real sale, check the receipt prints with the QR code and that **Receipts → the sale → Open on KRA** shows it.

## Licences (by days, per device)
- A new install runs a **14-day free trial**. Then (or when the licence ends) **selling stops**; receipts,
  reprints, reports and backups keep working. 7 days before the end the dashboard shows an orange warning.
- Make a key with the **BRV Licence Maker**: Product **BRV POS**, customer, device code, days → **Make licence**.
  It copies a WhatsApp message; the shop pastes the whole message in **Licence** (also on the sign-in screen) → **Activate**.
  Command line (Linux/Mac):
  ```
  python3 brv_pdf_etr/tools/licence_maker.py --key brv_licence_private_key.pem --product pos \
      --machine 7K2P-9QXA --days 365 --customer "Mama Duka Nakuru" --note "MPESA QWE123"
  python3 brv_pdf_etr/tools/licence_maker.py --key brv_licence_private_key.pem --list pos
  ```
- One private key file (`brv_licence_private_key.pem`) makes BRV PDF ETR and BRV POS licences. All licences are in
  `licences.csv` next to it (POS ones have `[POS]` in the note). Never put the key file on a client device.
- Turning the device date back stops selling until the date is right. A factory reset changes the device code
  (make a new licence for the new code).

## Technician lock
Locked for the shop (BRV only): VSCU address, KRA PIN/branch/serial, Connect device, receipt header and logo,
next invoice number, VAT-inclusive switch, restore from backup. The shop can still change: paper width, printer,
test print, backup, item classifications, users, items, customers.
- Unlock: Settings → **Unlock** → technician PIN (15 minutes, or **Lock now**).
- Forgot the PIN, or an older device already set up without one: BRV Licence Maker → device code →
  **BRV POS technician key** (valid 2 days, that device only) → in the app **Unlock → Forgot the PIN? Use a technician key**
  → paste → choose a new PIN. Command line: `licence_maker.py --key brv_licence_private_key.pem --machine 7K2P-9QXA --tech`.

## Backups
After every sale the app updates `Downloads/BRV POS/Backups/BRV-POS-backup.brvpos` (kept if the app is uninstalled).
New device or reinstall: sign-in screen → **Restore from backup**. The licence is for the old device: make one
for the new device code.

## Build
Push to `main` (changes in `brv_pos/`) → GitHub Actions **Build BRV POS** builds and analyses the app and makes a
release with `app-release.apk` (about 10 minutes).
