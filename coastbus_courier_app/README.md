# Coast Bus Courier

Handheld app (Android terminals with built-in 58 mm printer and barcode imager) + Odoo 17 Community back office.

| Part | Where |
|---|---|
| Android app | `coastbus_courier_app/` → GitHub Actions "Build Coast Bus Courier" → release `coastbus-courier-v1.0.N` (APK) |
| Odoo module | `odoo_addons/coastbus_courier/` (menu **Courier**) |
| Server installer | `coastbus_install.sh` (Odoo 17 + PostgreSQL in Docker, module installed, Kenya/KES, daily backups) |

## 1. Server (once)

On a fresh Ubuntu server (2 vCPU / 4 GB is enough), as root:

```
bash coastbus_install.sh                                   # http://SERVER-IP:8069
DOMAIN=courier.coastbus.co.ke bash coastbus_install.sh     # https (needed for M-Pesa STK push)
```

Point the domain's DNS (A record) to the server first. Running the script again updates the module (backup taken first; data and passwords kept). Odoo login: `admin`, password in `/opt/coastbus/.env`.

## 2. Odoo setup (Courier → Configuration)

1. **Branches**: Mombasa `MSA`, Voi `VOI`, Nairobi `NBO` … (code is printed on waybills and labels).
2. **Routes & tariffs**: for each From → To: base fare (covers the base kg), each extra kg, minimum charge. "Same tariff both ways" saves entering the return.
   Chargeable kg = the larger of real weight and volumetric (L×W×H ÷ 5000).
3. **Vehicles**: plate numbers.
4. **Staff & PINs**: every terminal user with role and PIN (4–6 digits):
   * Office clerk: book parcels, collect, day summary
   * Loader / Driver: load and offload vehicles (drivers also confirm shortages with their PIN)
   * Supervisor: everything + approvals (cancel, release without SMS code, shortage sign-off)
   Branch empty = can sign in at any branch (drivers).
5. **Terminals**: one per handheld, with its branch. The form shows an **activation key**.
6. **Account customers**: companies that book on credit (invoice).
7. **Settings**: insurance %, VAT, receipt text, payment methods, SMS provider, M-Pesa (Daraja), loss liability accounts.

## 3. Terminal

Install the APK (64-bit; 32-bit only for old handhelds). Open it and type the **activation key** only: the server address is built into the APK and is never shown or typed on the terminal (GitHub repository variable `COURIER_SERVER`; without it the build uses `https://coastbus.brvsystems.co.ke`). Staff then tap their name and enter their PIN. The terminal locks itself after 10 idle minutes (Settings).

Hardware scanner: works in broadcast mode (Sunmi, Urovo, Newland, iData, Seuic, Chainway, Honeywell, Zebra DataWedge) and in keyboard mode. The camera button scans too.

## 4. Daily work

**Book parcel (clerk)**: destination, sender, receiver, contents, weight, pieces (optional size, fragile, insurance) → amount shown live → payment: Cash, M-Pesa code, M-Pesa prompt (STK, needs internet) or Account → prints the **receipt** (tracking QR) and **one label per piece** (QR + barcode `CB-MSA-07-00012/2`). The sender and receiver get an SMS with the tracking link.

**Load vehicle (loader)**: New trip → final stop, vehicle, driver → scan every piece as it goes on (green beep = OK; buzz = duplicate, wrong branch, already on another trip, collected/cancelled). Parcels for a branch on the way (e.g. Voi) are allowed after a confirmation. **Finish loading & depart** → prints the **departure manifest** for the driver and dispatcher to sign. From now on the driver is the custodian.

**Offload vehicle (destination)**: pick the expected vehicle (or scan the manifest slip QR) → scan every piece off; the counter shows `received / expected`. Pieces for another branch: "leave it on the vehicle". **Finish**:
* all present → **driver clearance** printed, receivers get an SMS with the 6-digit collection code;
* missing pieces → red **SHORTAGE** screen: scan again, or record it: driver confirms with PIN, supervisor approves → **shortage docket** printed, the parcel is marked missing and an investigation opens in Odoo (Courier → Shortages & losses) with the custody (driver, vehicle, loading scan time). Unexpected parcels (offloaded but never loaded) are recorded too.

**Collect parcel (clerk)**: scan the receiver's SMS link/receipt, type the waybill number or the receiver's phone → enter the SMS code → release (or ID number + supervisor PIN) → collection slip printed; the sender gets an SMS.

**Track**: any label, receipt, waybill number or phone → status and the full custody history. Reprint receipts and labels. Cancel (before loading, supervisor) → credit note in Odoo.

**My day**: bookings and money by payment method; print for the cash hand-over (supervisors can switch to the whole branch).

## 5. Offline

Everything is saved on the terminal first and sent to Odoo automatically (every 30 s and after each action). The chip in the top bar shows *Up to date*, *Offline · N to send* or *N problems*. Problems (e.g. a pre-printed label number already used) are listed under **Sync problems** with the reason; send again or discard (supervisor). M-Pesa prompt and looking up parcels from other branches need the internet.

## 6. Back office (Odoo)

* **Waybills**, **Waiting for collection** (per branch, days waiting), **Trip manifests** (loaded vs offloaded per piece), **Shortages & losses** (vehicle sweep → found / confirm loss → optional liability entry against the driver).
* **Reports**: revenue and volumes (pivot/graph by branch, route, clerk, payment, day), custody log, SMS, M-Pesa, terminal sync log.
* Each waybill makes a posted customer invoice (freight + insurance); cash and M-Pesa are registered as payments in the branch cash journal / M-Pesa journal; account customers stay unpaid on their invoice.
* Public tracking page: `https://SERVER/t/<token>` (QR on the receipt) and `https://SERVER/track`.

## 7. SMS and M-Pesa

* **SMS** (Settings → Courier → SMS): until a provider is chosen, messages wait in Reports → SMS and go out once it is set. Africa's Talking (username, API key, sender ID) or any HTTP SMS API (URL, headers, body with `{phone}` `{message}` `{sender}`). "Send test SMS" checks it. Message texts are editable.
* **M-Pesa STK push**: Daraja consumer key/secret, shortcode, passkey, paybill or till; needs the https domain (callback `https://SERVER/courier/mpesa/callback`). Tick "M-Pesa STK push" under payment methods.
