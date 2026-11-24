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
    utange_staff_reason = fields.Char('Staff bill note', copy=False, readonly=True)

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

    # ------------------------------------------------------------------
    # Staff bills from the Odoo POS screen: the employee and the note travel with the order
    # ------------------------------------------------------------------
    @api.model
    def _order_fields(self, ui_order):
        res = super()._order_fields(ui_order)
        if ui_order.get('utange_staff_id'):
            res['utange_staff_id'] = int(ui_order['utange_staff_id'])
            res['utange_staff_reason'] = (ui_order.get('utange_staff_reason') or '').strip()[:200] or False
        return res

    @api.model
    def _process_order(self, order, draft, existing_order):
        data = order.get('data') or {}
        staff_pms = self.env['pos.payment.method'].sudo().search([('utange_staff', '=', True)]).ids
        used = [p[2].get('payment_method_id') for p in (data.get('statement_ids') or [])
                if isinstance(p, (list, tuple)) and len(p) > 2 and isinstance(p[2], dict)]
        if staff_pms and any(m in staff_pms for m in used):
            emp = self.env['hr.employee'].sudo().browse(int(data.get('utange_staff_id') or 0)).exists()
            if not emp:
                raise UserError('Staff bills: choose the employee (from the employees list).')
            if len((data.get('utange_staff_reason') or '').strip()) < 3:
                raise UserError('Staff bills: write a note (it shows in the Employees bills report).')
            data['partner_id'] = self._utange_staff_partner(emp).id
        return super()._process_order(order, draft, existing_order)

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
