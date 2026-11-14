from odoo import _, api, fields, models

# What a person may do in Utange (handheld, Odoo POS screen, Odoo, Manager app).
PERMS = [
    ('sell', 'Sell on the handheld'),
    ('open', 'Open shifts (opening stock count)'),
    ('close', 'Close shifts (closing stock count)'),
    ('requisition', 'Make requisitions'),
    ('purchase', 'Receive purchases (Manager app)'),
    ('items', 'Edit items and prices (Manager app)'),
]
PERM_LABEL = dict(PERMS)


class UtangePermissionMixin(models.AbstractModel):
    _name = 'utange.permission.mixin'
    _description = 'Utange permissions'

    utange_restrict = fields.Boolean(
        'Restrict Utange POS',
        help='Off: this person can do everything in Utange (as before). On: only what is ticked below.')
    utange_perm_sell = fields.Boolean(PERM_LABEL['sell'])
    utange_perm_open = fields.Boolean(PERM_LABEL['open'])
    utange_perm_close = fields.Boolean(PERM_LABEL['close'])
    utange_perm_requisition = fields.Boolean(PERM_LABEL['requisition'])
    utange_perm_purchase = fields.Boolean(PERM_LABEL['purchase'])
    utange_perm_items = fields.Boolean(PERM_LABEL['items'])


class ResUsers(models.Model):
    _name = 'res.users'
    _inherit = ['res.users', 'utange.permission.mixin']

    utange_approver = fields.Boolean(
        'Utange: can approve',
        help='Can approve stock count differences and requisitions: with their employee PIN on the Odoo POS '
             'screen or the handheld, and in the Manager app / Odoo with this login.\n'
             'When nobody is ticked, Point of Sale administrators (and "Advanced rights" employees) approve.')

    def write(self, vals):
        res = super().write(vals)
        if 'utange_approver' in vals:
            # the same person's employee record (PIN on the POS / handheld) follows the user
            self.sudo().employee_ids.write({'utange_approver': vals['utange_approver']})
        return res

    @api.model
    def _utange_approvers_chosen(self):
        """True when at least one user or employee is ticked "Utange: can approve"."""
        return bool(self.sudo().search_count([('utange_approver', '=', True)], limit=1)
                    or self.env['hr.employee'].sudo().search_count([('utange_approver', '=', True)], limit=1))

    def _utange_can_approve(self):
        """Can this user approve counts / requisitions (Manager app, Odoo)?"""
        self.ensure_one()
        if self._utange_approvers_chosen():
            return bool(self.sudo().utange_approver or self.sudo().employee_ids.filtered('utange_approver'))
        return self.has_group('point_of_sale.group_pos_manager') or self.has_group('stock.group_stock_manager')

    def _utange_allowed(self, perm):
        """Administrators are never restricted (same as BRV Access)."""
        self.ensure_one()
        u = self.sudo()
        if u._is_superuser() or u.has_group('base.group_system') or not u.utange_restrict:
            return True
        return bool(u['utange_perm_%s' % perm])

    def _utange_denied(self, perm):
        return '' if self._utange_allowed(perm) else _(
            '%s is not allowed to: %s. Ask the administrator (Settings > Users > BRV Access).') % (
            self.name, PERM_LABEL[perm].lower())


class HrEmployee(models.Model):
    _name = 'hr.employee'
    _inherit = ['hr.employee', 'utange.permission.mixin']

    utange_approver = fields.Boolean(
        'Utange: can approve', groups='hr.group_hr_user,point_of_sale.group_pos_manager,base.group_erp_manager',
        help="This person's PIN approves stock count differences on the Odoo POS screen and the handheld.")

    def _utange_allowed(self, perm):
        """An employee with an Odoo login follows the login's settings; others their own."""
        self.ensure_one()
        e = self.sudo()
        if e.user_id:
            return e.user_id._utange_allowed(perm)
        return (not e.utange_restrict) or bool(e['utange_perm_%s' % perm])

    def _utange_denied(self, perm):
        return '' if self._utange_allowed(perm) else _(
            '%s is not allowed to: %s. Ask the administrator.') % (self.name, PERM_LABEL[perm].lower())
