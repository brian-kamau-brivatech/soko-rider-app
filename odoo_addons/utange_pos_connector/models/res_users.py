from odoo import api, fields, models


class ResUsers(models.Model):
    _inherit = 'res.users'

    utange_approver = fields.Boolean(
        'Utange: can approve',
        help='Can approve stock count differences and requisitions: with their employee PIN on the Odoo POS '
             'screen or the handheld, and in the Manager app / Odoo with this login.\n'
             'When nobody is ticked, Point of Sale administrators (and "Advanced rights" employees) approve.')

    @property
    def SELF_READABLE_FIELDS(self):
        return super().SELF_READABLE_FIELDS + ['utange_approver']

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


class HrEmployee(models.Model):
    _inherit = 'hr.employee'

    utange_approver = fields.Boolean(
        'Utange: can approve', groups='hr.group_hr_user,point_of_sale.group_pos_manager,base.group_erp_manager',
        help='This person\'s PIN approves stock count differences on the Odoo POS screen and the handheld.')
