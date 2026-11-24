from odoo import SUPERUSER_ID, api


def migrate(cr, version):
    """Every Point of Sale gets the "Staff bills" payment method (credit to an employee)."""
    env = api.Environment(cr, SUPERUSER_ID, {})
    for config in env['pos.config'].search([('active', '=', True)]):
        config._utange_staff_method()
