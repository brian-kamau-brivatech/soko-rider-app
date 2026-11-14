{
    'name': 'Utange POS Handheld',
    'version': '17.0.7.0',
    'license': 'LGPL-3',
    'category': 'Sales/Point of Sale',
    'summary': 'Handheld POS app for Utange: POS employee login, shift stock sheets, bar requisitions',
    'description': """
Connects the Utange POS Android app (handheld) to Odoo Point of Sale.

* Cashiers sign in with their POS employee PIN (Log in with employees).
* Sales are saved as real POS orders in the open session.
* Opening a shift requires counting the stock (stock sheet); closing counts it again.
  The sheet shows opening, received, sent out, sold, expected, counted and variances
  like the paper stock book, and prints as PDF.
* Requisitions: the bar asks the main store for items; a manager approves and an
  internal transfer is created.
""",
    'author': 'BRV Integrated Systems',
    'depends': ['point_of_sale', 'pos_hr', 'stock', 'hr', 'mail'],
    'data': [
        'security/security.xml',
        'security/ir.model.access.csv',
        'data/sequence.xml',
        'views/stock_sheet_views.xml',
        'views/requisition_views.xml',
        'views/pos_config_views.xml',
        'report/stock_sheet_report.xml',
        'views/res_users_views.xml',
        'views/menu.xml',
    ],
    'assets': {
        'point_of_sale._assets_pos': [
            'utange_pos_connector/static/src/**/*',
        ],
    },
    'installable': True,
    'application': False,
}
