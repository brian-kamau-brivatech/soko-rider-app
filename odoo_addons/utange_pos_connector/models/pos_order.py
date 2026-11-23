# -*- coding: utf-8 -*-
from odoo import fields, models


class PosOrder(models.Model):
    _inherit = 'pos.order'

    # Utange POS handheld: what each kitchen / bar printer already printed for this table order,
    # as JSON {printer_id: {product_id: qty}}. Odoo POS keeps its own copy in last_order_preparation_change.
    utange_sent = fields.Text(string='Handheld: sent to preparation printers', copy=False)
