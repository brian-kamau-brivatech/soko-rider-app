from odoo import _, models
from odoo.exceptions import UserError


class PosSession(models.Model):
    """No shift opens (Odoo POS or handheld) before the opening stock is counted and confirmed,
    and none closes before the closing count is confirmed (when the POS asks for it)."""
    _inherit = 'pos.session'

    def _utange_sheet(self):
        self.ensure_one()
        return self.env['utange.stock.sheet'].sudo().search(
            [('session_id', '=', self.id), ('state', '!=', 'draft')], order='id desc', limit=1)

    def _utange_check_open(self):
        Sheet = self.env['utange.stock.sheet'].sudo()
        for s in self:
            cfg = s.config_id
            if s.rescue or not cfg.utange_require_sheet or s._utange_sheet():
                continue
            ready = Sheet.search([('config_id', '=', cfg.id), ('session_id', '=', False), ('state', '=', 'open')],
                                 order='id desc', limit=1)
            if ready:
                ready.session_id = s.id
                continue
            raise UserError(_(
                "Count the opening stock first.\n\n"
                "On the Utange handheld: More > Shift > Count stock and open.\n"
                "In Odoo: Point of Sale > Handheld > Count stock > Confirm opening count.\n"
                "Then open the session again."))

    def action_pos_session_open(self):
        # Without cash control Odoo opens the session at once: check now.
        self.filtered(lambda s: s.state == 'opening_control' and not (s.config_id.cash_control and not s.rescue)) \
            ._utange_check_open()
        return super().action_pos_session_open()

    def set_cashbox_pos(self, cashbox_value, notes):
        self._utange_check_open()
        return super().set_cashbox_pos(cashbox_value, notes)

    def _cannot_close_session(self, bank_payment_method_diffs=None):
        res = super()._cannot_close_session(bank_payment_method_diffs)
        if res:
            return res
        for s in self:
            if s.rescue or not s.config_id.utange_count_at_close:
                continue
            sheet = s._utange_sheet()
            if not sheet or not sheet.close_confirmed:
                return {'successful': False, 'redirect': False, 'message': _(
                    "Count the closing stock first.\n\n"
                    "On the Utange handheld: More > Shift > Count stock and close.\n"
                    "In Odoo: Point of Sale > Handheld > Count stock > Start closing count > Confirm closing count.\n"
                    "Then close the session.")}
        return False

    def _validate_session(self, balancing_account=False, amount_to_balance=0, bank_payment_method_diffs=None):
        res = super()._validate_session(balancing_account, amount_to_balance, bank_payment_method_diffs)
        for s in self.filtered(lambda x: x.state == 'closed'):
            s.env['utange.stock.sheet'].sudo().search(
                [('session_id', '=', s.id), ('close_confirmed', '=', True), ('state', '!=', 'closed')]).write({'state': 'closed'})
        return res
