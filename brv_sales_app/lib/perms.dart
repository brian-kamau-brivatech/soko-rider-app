/// Rights a role can have. A user gets the rights of their role.
class P {
  static const sell = 'sell';
  static const discount = 'discount';
  static const priceChange = 'price_change';
  static const refund = 'refund';
  static const sellNoStock = 'sell_no_stock';
  static const shift = 'shift';
  static const allSales = 'all_sales';
  static const dashboard = 'dashboard';
  static const reports = 'reports';
  static const products = 'products';
  static const stockAdjust = 'stock_adjust';
  static const reqCreate = 'req_create';
  static const reqApprove = 'req_approve';
  static const purchase = 'purchase';
  static const purchaseReceive = 'purchase_receive';
  static const supplierPay = 'supplier_pay';
  static const customers = 'customers';
  static const customerPay = 'customer_pay';
  static const expenses = 'expenses';
  static const accounting = 'accounting';
  static const users = 'users';
  static const roles = 'roles';
  static const settings = 'settings';
  static const backup = 'backup';

  /// (key, label, group) in the order shown on the role screen.
  static const all = <(String, String, String)>[
    (sell, 'Sell (make sales)', 'Point of sale'),
    (discount, 'Give discounts', 'Point of sale'),
    (priceChange, 'Change the price on a sale', 'Point of sale'),
    (refund, 'Refund sales', 'Point of sale'),
    (sellNoStock, 'Sell items that show no stock', 'Point of sale'),
    (shift, 'Open and close shifts (cash drawer)', 'Point of sale'),
    (allSales, 'See everyone\'s sales (not only own)', 'Point of sale'),
    (customers, 'Manage customers', 'Customers'),
    (customerPay, 'Receive customer payments (credit)', 'Customers'),
    (products, 'Add and edit products, prices, categories', 'Inventory'),
    (stockAdjust, 'Adjust stock, stock counts, opening stock', 'Inventory'),
    (reqCreate, 'Make requisitions', 'Inventory'),
    (reqApprove, 'Approve requisitions (moves stock)', 'Inventory'),
    (purchase, 'Create purchase orders, suppliers', 'Purchases'),
    (purchaseReceive, 'Receive purchases into stock', 'Purchases'),
    (supplierPay, 'Pay suppliers', 'Purchases'),
    (expenses, 'Record expenses', 'Accounting'),
    (accounting, 'Accounting: accounts, journal, statements', 'Accounting'),
    (dashboard, 'Admin dashboard (monitor sales)', 'Reports'),
    (reports, 'Reports', 'Reports'),
    (users, 'Manage users and PINs', 'Administration'),
    (roles, 'Manage roles and rights', 'Administration'),
    (settings, 'Business settings, printer, payment methods', 'Administration'),
    (backup, 'Backup and restore', 'Administration'),
  ];

  static List<String> get keys => [for (final p in all) p.$1];

  /// Default roles made on first start: (name, rights).
  static final defaults = <(String, List<String>)>[
    ('Owner', keys),
    ('Manager', keys.where((k) => k != roles && k != backup).toList()),
    ('Cashier', [sell, shift, customers, customerPay, reqCreate]),
    ('Storekeeper', [products, stockAdjust, reqCreate, reqApprove, purchaseReceive, reports]),
    ('Accountant', [reports, dashboard, expenses, accounting, supplierPay, customerPay, allSales, customers]),
  ];
}
