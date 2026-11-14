from odoo import _, fields, models
from odoo.exceptions import UserError


def _counts(counts):
    out = {}
    for c in counts or []:
        try:
            out[int(c.get('product_id'))] = float(c.get('qty'))
        except (TypeError, ValueError, AttributeError):
            continue
    return out


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

    # Without cash control Odoo opens the session as soon as it is created; the POS screen then
    # shows the stock count popup before anything can be sold (static/src/pos_patches.js).

    def set_cashbox_pos(self, cashbox_value, notes):
        self._utange_check_open()
        return super().set_cashbox_pos(cashbox_value, notes)

    # ------------------------------------------------------------------
    # Called by the Odoo POS screen (popups)
    # ------------------------------------------------------------------
    def _utange_employee(self, employee_id):
        emp = self.env['hr.employee'].sudo().browse(int(employee_id)).exists() if employee_id else False
        return emp or self.env.user.employee_id or None

    def _utange_can_approve_now(self, employee_id):
        emp = self._utange_employee(employee_id) if employee_id else None
        return bool(self._utange_approver(emp, ''))

    def utange_open_lines(self, employee_id=False):
        """Opening stock popup: {'needed': bool, 'lines': [...]}."""
        self.ensure_one()
        cfg = self.config_id
        if self.rescue or not cfg.utange_require_sheet or self.state == 'closed':
            return {'needed': False}
        if self._utange_sheet():
            return {'needed': False}
        Sheet = self.env['utange.stock.sheet'].sudo()
        ready = Sheet.search([('config_id', '=', cfg.id), ('session_id', '=', False), ('state', '=', 'open')],
                             order='id desc', limit=1)
        if ready:
            ready.session_id = self.id
            return {'needed': False, 'sheet': ready.name}
        return {'needed': True, 'lines': Sheet._opening_items(cfg), 'corrects': bool(cfg.utange_apply_open_count),
                'can_approve': self._utange_can_approve_now(employee_id)}

    def _utange_approver(self, employee, manager_pin):
        """Who approves differences right now: a manager's PIN, or the signed-in cashier/user being a manager."""
        cfg = self.config_id
        if manager_pin:
            mgr, err = cfg._utange_manager_by_pin(manager_pin)
            if not mgr:
                raise UserError(err)
            return mgr.name
        if employee and cfg.module_pos_hr:
            return employee.name if cfg._utange_is_manager(employee=employee) else None
        return self.env.user.name if cfg._utange_is_manager(user=self.env.user) else None

    def utange_confirm_open(self, counts, note='', employee_id=False, manager_pin=''):
        self.ensure_one()
        sheet = self._utange_sheet()
        if not sheet:
            emp = self._utange_employee(employee_id)
            by = self._utange_approver(emp, manager_pin)
            sheet = self.env['utange.stock.sheet'].sudo()._start(self.config_id, self, _counts(counts), employee=emp)
            sheet.open_user_id = self.env.uid
            sheet.message_post(body='Opening stock confirmed on the Odoo POS screen%s.' % ((' by %s' % emp.name) if emp else ''))
            sheet._settle('open', by, note)
        return {'name': sheet.name, 'diffs': sheet.open_diff_count, 'approval': sheet.open_approval}

    def utange_close_lines(self, employee_id=False):
        """Closing stock popup: {'needed': bool, 'lines': [...]} with the expected quantities."""
        self.ensure_one()
        cfg = self.config_id
        if self.rescue or not cfg.utange_count_at_close:
            return {'needed': False}
        Sheet = self.env['utange.stock.sheet'].sudo()
        sheet = self._utange_sheet() or Sheet._start(cfg, self, {}, outside=True)
        if sheet.close_confirmed:
            return {'needed': False, 'sheet': sheet.name}
        sheet._refresh_movements(until=fields.Datetime.now())
        return {'needed': True, 'sheet': sheet.name, 'can_approve': self._utange_can_approve_now(employee_id), 'lines': [{
            'product_id': l.product_id.id, 'name': l.product_id.display_name, 'point': l.point or '',
            'uom': l.product_id.uom_id.name or '', 'opening': l.counted_open, 'received': l.received,
            'sent_out': l.sent_out, 'sold': l.sold, 'ref': l.expected_close} for l in sheet.line_ids]}

    def utange_confirm_close(self, counts, note='', employee_id=False, manager_pin=''):
        self.ensure_one()
        Sheet = self.env['utange.stock.sheet'].sudo()
        sheet = self._utange_sheet() or Sheet._start(self.config_id, self, {}, outside=True)
        if not sheet.close_confirmed:
            emp = self._utange_employee(employee_id)
            by = self._utange_approver(emp, manager_pin)
            sheet._finish(_counts(counts), employee=emp)
            sheet.write({'close_user_id': self.env.uid, 'state': 'closing'})
            sheet.message_post(body='Closing stock confirmed on the Odoo POS screen%s.' % ((' by %s' % emp.name) if emp else ''))
            sheet._settle('close', by, note)
        return {'name': sheet.name, 'diffs': sheet.close_diff_count, 'value': sheet.close_diff_value,
                'approval': sheet.close_approval}

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
