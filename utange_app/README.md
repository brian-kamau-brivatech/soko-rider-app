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

## Staff, bills and counts (module 17.0.9.0)

* **Waiter / cashier rights**: "Take payment (charge)" is a right of its own. A waiter takes orders, sends them to the
  kitchen / bar and prints the bill, but cannot charge. Set it in Odoo (BRV Access tab) or in the Manager app
  (Reports > Staff rights: Waiter / Cashier / Everything). People who could sell before keep charging.
* **Counts are for managers**: with "Only managers change stock counts" (Handheld settings, on by default) a cashier
  opens and closes with the figures the system shows. A shortage found at opening is sold with the **Staff bills** payment to
  the person who closed the last shift (Charge > Staff bills: choose the employee from the list and write a note).
  The module adds the "Staff bills" payment method to every Point of Sale by itself. On the Odoo POS screen too, paying
  with Staff bills asks for the employee (employees list only) and a note; Odoo refuses a Staff bills order without them.
* **Employees bills**: Odoo > Point of Sale > Handheld > Employees bills, and Manager app > Reports > Employees bills
  (clear when paid / deducted).
* **Open bills per person**: tables show the waiter's name; "My bills" filter; the people icon lists unpaid bills per
  person; closing the shift shows each person's sales and whether their bills are cleared.
* **Internal note** per item (cart > note icon): printed under the item on the kitchen / bar ticket and kept on the Odoo order.
* **Bill** print before payment; **prices and total** on kitchen / captain tickets.
* **Manager app > Reports**: sales report (day, payment, cashier, category, item), stock report per day (opening,
  in, out, sold, closing, differences), stock take of the main store / bar / kitchen, transfer main store -> bar / kitchen.
* Fix: "Sold" on the closing count now takes every paid order of the shift (orders from a till whose clock is behind
  were left out).

## Install / update the module (server)
Copy `odoo_addons/utange_server_install.sh` to the server and run it (backs up the database first).

## Build
Push to main (changes in `utange_app/`) -> GitHub Actions "Build Utange apps" -> two releases:
`Utange-POS.apk` and `Utange-Manager.apk`. Optional repository variable `UTANGE_URL` pre-fills the Odoo address.
