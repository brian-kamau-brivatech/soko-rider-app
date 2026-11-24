# -*- coding: utf-8 -*-
from odoo import api, fields, models
from odoo.exceptions import UserError


class PosOrder(models.Model):
    _inherit = 'pos.order'

    # Utange POS handheld: what each kitchen / bar printer already printed for this table order,
    # as JSON {printer_id: {product_id: qty}}. Odoo POS keeps its own copy in last_order_preparation_change.
    utange_sent = fields.Text(string='Handheld: sent to preparation printers', copy=False)

    # Employees bills: a credit sale to a member of staff (e.g. the soda missing at the next opening is
    # sold to the person who closed the shift). Paid with the Customer Account method, on the employee's contact.
    utange_staff_id = fields.Many2one('hr.employee', 'Employee bill for', index=True, copy=False, readonly=True)
    utange_staff_cleared = fields.Boolean('Employee bill cleared', copy=False, readonly=True)
    utange_staff_cleared_by = fields.Char('Cleared by', copy=False, readonly=True)
    utange_staff_cleared_date = fields.Datetime('Cleared on', copy=False, readonly=True)
    utange_staff_reason = fields.Char('Employee bill reason', copy=False, readonly=True)

    def _utange_check_clear(self):
        u = self.env.user
        if not self.env.su and not (u._utange_can_approve() or u.has_group('point_of_sale.group_pos_manager')):
            raise UserError('Only a manager can clear employees bills.')

    def action_utange_clear_staff(self):
        self._utange_check_clear()
        todo = self.filtered(lambda o: o.utange_staff_id and not o.utange_staff_cleared)
        todo.write({'utange_staff_cleared': True, 'utange_staff_cleared_by': self.env.user.name,
                    'utange_staff_cleared_date': fields.Datetime.now()})
        return True

    def action_utange_unclear_staff(self):
        self._utange_check_clear()
        self.filtered('utange_staff_cleared').write({'utange_staff_cleared': False, 'utange_staff_cleared_by': False,
                                                      'utange_staff_cleared_date': False})
        return True

    @api.model
    def _utange_staff_partner(self, employee):
        """The employee's own contact (work contact), made when missing."""
        employee = employee.sudo()
        partner = employee.work_contact_id
        if not partner:
            partner = self.env['res.partner'].sudo().create({'name': employee.name, 'email': employee.work_email or False,
                                                              'phone': employee.mobile_phone or employee.work_phone or False})
            employee.work_contact_id = partner.id
        return partner
