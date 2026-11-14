# BRV Pos Sales

Offline point of sale for Android phones and handheld POS devices, by BRV Integrated Systems.
Everything is kept on the device (no internet needed). It is separate from the BRV POS eTIMS app.

## What it does
- **Sell**: product grid with categories, search and barcode, cart with quantity / discount / price change (by right),
  split payments (Cash, M-Pesa, Card, Credit to a customer account, any extra method), change, receipt printing.
- **Users and PINs**: several people share one device. Each taps their name and types their own 4-6 digit PIN.
  The app locks itself after a few minutes without a touch (Settings).
- **Roles and rights**: Owner, Manager, Cashier, Storekeeper, Accountant (editable) plus your own roles.
  24 rights, e.g. sell, discount, refund, open shifts, approve requisitions, receive purchases, accounting, users.
- **Shifts**: open with a cash float, close by counting the cash. Short/over is posted. Z report printed.
- **Stock**: per location (Main Store, Shop, Bar, Kitchen ...), stock counts, opening stock, every movement, low-stock alerts,
  average cost.
- **Requisitions**: a selling point asks the store for items; someone with the right approves and the stock moves.
- **Purchases**: orders to suppliers, receive into a location (stock and cost updated), pay suppliers, what you owe.
- **Customers**: credit sales with limits, statements, receive payments.
- **Accounting**: double-entry. Every sale, refund, purchase, payment, expense and stock correction posts a journal entry.
  Profit and loss, balance sheet, chart of accounts with ledgers, manual entries (opening balances, owner's money).
- **Reports**: summary, by item, staff, payment, day, category, VAT, stock value, customers owing, suppliers owed. Print or share as PDF.
- **Owner dashboard**: today / weekly / monthly sales, orders, average sale, gross profit, revenue chart against the previous
  period, orders chart, trending items, latest orders, staff, payments, open shifts, low stock, waiting requisitions.
- **Backup**: one file in Downloads/BRV Pos Sales/Backups, made automatically at every shift close; share it to
  Google Drive / Gmail / WhatsApp. Restore on a new device.

## First start (owner)
1. Install `BRV-Pos-Sales-64bit.apk` (use `-32bit` only if Android says the app is not compatible).
2. Enter the business name, phone, KRA PIN (optional) and whether you are VAT registered.
3. Enter your name and your PIN (twice). Write down the **recovery code** shown: it resets the owner PIN if forgotten.

## Set up the business (More / Stock)
1. **Locations** (Stock > Locations): Main Store and Shop exist. Add Bar, Kitchen, Branch 2 as needed. A *store* gives stock,
   a *selling point* sells.
2. **Categories** and **Products** (Stock > Products): name, selling price (incl. VAT), cost price, VAT rate, barcode,
   reorder level, and the opening quantity with its location.
3. **Payment methods** (More > Payment methods): add e.g. "Equity Bank" or "Airtel Money"; each gets its own account.
4. **Opening balances** (More > Accounting > Manual entry): e.g. cash in hand: Debit Cash, Credit Owner's capital.
5. **Printer** (More > Printer): handheld with built-in printer = Automatic. Bluetooth printer: pair it in Android settings,
   then pick it. Choose 58 or 80 mm and print a test. On a phone without a printer, switch off
   "Print the receipt after each sale" in Business settings.

## Users and PINs
More > Users and PINs > **+ User**: name, role, PIN (4-6 digits, different for everyone). Tell the person their PIN.
- Change a PIN: open the user, type a new PIN, Save.
- Disable someone who left: switch off Active (their history stays).
- Forgot PIN: on the PIN screen tap *Forgot PIN?*: a user manager types their PIN and sets a new one; the owner can also
  use the recovery code.
- 5 wrong PINs lock that user for 5 minutes.
- Roles: Users > Roles. Tick the rights of each role. The Owner role always has everything.

## A normal day
1. Cashier taps their name, PIN, **Open shift** (count the float).
2. **Sell** tab: tap items, View sale, Charge, choose payment(s), Complete sale. Receipt prints.
3. Running low at the shop? Stock > Requisitions > Request from Main Store; the manager approves and the stock moves.
4. Goods from a supplier: Stock > Purchases > Purchase > Save and receive now. Pay later from the purchase or Suppliers.
5. Expenses: More > Expenses (paid from the till during a shift = taken off the expected cash).
6. End of shift: More > Shift > count the cash > Close shift: Z report prints and a backup is made.
7. Owner: Home = dashboard; Reports for any period; Accounting for profit and loss and the balance sheet.

## Offline and several devices
The app never needs internet. Each device keeps its own data. To move to a new device: on the old one
More > Backup and restore > Back up and share; on the new one install, set up quickly, then Restore from that file.
