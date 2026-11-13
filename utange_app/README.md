# Utange POS + Utange Manager

Two Android apps from one code base (`APP_MODE`), both on Odoo 17 (Utange: container BRV_1.0, database `utangevillage`)
through the Odoo module `odoo_addons/utange_pos_connector`.

| App | Who | Signs in with | Does |
|---|---|---|---|
| **Utange POS** | Handheld at the bar | Device PIN once (BRV), then POS employee + PIN | Sell (POS orders in the open session), print receipts, open shift = count stock, close shift = count stock + cash, requisitions to the store, stock, sales |
| **Utange Manager** | Managers' phones | Their Odoo login (POS or Inventory manager) | Today's sales, open shifts, stock sheets (opening vs received vs sold vs closing, variances), approve / reject requisitions |

## Odoo side (module utange_pos_connector)
- Point of Sale > Handheld > Shift stock sheets / Stock variances / Requisitions / Handheld settings.
- Handheld settings per POS: count stock to open (default on), count to close (default on), stock sheet categories,
  **Requisitions from (store)** location.
- Device PIN: System Parameter `utange_pos.device_pin` (the install script makes one).
- Cashiers: POS settings > Log in with employees; each employee's PIN. Managers (advanced rights) can close shifts and move cash.
- Requisition approved -> internal transfer store -> bar (Inventory). When the store validates it, the requisition is Issued.
- Stock sheet: printable (Print button), same columns as the paper book.

## Install / update the module (server)
Copy `odoo_addons/utange_server_install.sh` to the server and run it (backs up the database first).

## Build
Push to main (changes in `utange_app/`) -> GitHub Actions "Build Utange apps" -> two releases:
`Utange-POS.apk` and `Utange-Manager.apk`. Optional repository variable `UTANGE_URL` pre-fills the Odoo address.
