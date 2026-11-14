{
    'name': 'Utange POS in BRV Access',
    'version': '17.0.1.0',
    'license': 'LGPL-3',
    'category': 'Hidden',
    'summary': 'Shows the Utange POS permissions inside the BRV Access tab of each user',
    'author': 'BRV Integrated Systems',
    'depends': ['utange_pos_connector', 'brv_user_access'],
    'data': ['views/res_users_views.xml'],
    'auto_install': True,
    'installable': True,
}
