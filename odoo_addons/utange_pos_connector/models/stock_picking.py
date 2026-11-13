from odoo import fields, models


class StockPicking(models.Model):
    _inherit = 'stock.picking'

    utange_requisition_id = fields.Many2one('utange.requisition', 'Requisition', index=True, copy=False, readonly=True)

    def _action_done(self):
        res = super()._action_done()
        self.filtered(lambda p: p.state == 'done' and p.utange_requisition_id).utange_requisition_id.sudo()._utange_issued()
        return res
