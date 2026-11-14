from odoo import api, fields, models
from odoo.exceptions import UserError


class UtangeRequisition(models.Model):
    """The bar asks the main store for items. A manager approves it in Odoo, which
    creates an internal transfer store -> bar; it is done when the store validates it."""
    _name = 'utange.requisition'
    _description = 'Bar requisition'
    _inherit = ['mail.thread', 'mail.activity.mixin']
    _order = 'id desc'

    name = fields.Char(required=True, default='/', copy=False, readonly=True)
    date = fields.Datetime(default=fields.Datetime.now, readonly=True)
    config_id = fields.Many2one('pos.config', 'Point of Sale', required=True, index=True,
                                default=lambda s: s.env['pos.config'].search([('active', '=', True)], limit=1))
    session_id = fields.Many2one('pos.session', 'Session', readonly=True)
    employee_id = fields.Many2one('hr.employee', 'Requested by', readonly=True,
                                  default=lambda s: s.env.user.employee_id)
    point = fields.Selection([('bar', 'Bar'), ('kitchen', 'Kitchen'), ('main', 'POS')], string='For', default='bar',
                             required=True, tracking=True)
    location_src_id = fields.Many2one('stock.location', 'From (main store)', required=True, domain=[('usage', '=', 'internal')])
    location_dest_id = fields.Many2one('stock.location', 'To', required=True, domain=[('usage', '=', 'internal')])
    company_id = fields.Many2one('res.company', default=lambda s: s.env.company, readonly=True)
    state = fields.Selection([
        ('submitted', 'Waiting approval'),
        ('approved', 'Approved - to issue'),
        ('done', 'Issued'),
        ('rejected', 'Rejected'),
        ('cancel', 'Cancelled'),
    ], default='submitted', required=True, tracking=True, readonly=True)
    note = fields.Text('Reason / note')
    manager_note = fields.Text('Manager note', tracking=True)
    line_ids = fields.One2many('utange.requisition.line', 'requisition_id', 'Items', copy=True)
    picking_id = fields.Many2one('stock.picking', 'Transfer', readonly=True, copy=False)
    approved_by_id = fields.Many2one('res.users', 'Approved by', readonly=True, copy=False)
    approved_date = fields.Datetime(readonly=True, copy=False)
    item_count = fields.Integer(compute='_compute_item_count')

    @api.onchange('config_id', 'point')
    def _onchange_point(self):
        for r in self:
            if r.config_id:
                r.location_src_id = r.config_id._utange_store_location()
                r.location_dest_id = r.config_id._utange_point_location(r.point if r.point in ('bar', 'kitchen') else False)

    @api.depends('line_ids')
    def _compute_item_count(self):
        for r in self:
            r.item_count = len(r.line_ids)

    @api.model_create_multi
    def create(self, vals_list):
        for v in vals_list:
            if v.get('name', '/') == '/':
                v['name'] = self.env['ir.sequence'].next_by_code('utange.requisition') or '/'
            cfg = self.env['pos.config'].browse(v.get('config_id')) if v.get('config_id') else \
                self.env['pos.config'].search([('active', '=', True)], limit=1)
            if cfg:
                v.setdefault('location_src_id', cfg._utange_store_location().id)
                v.setdefault('location_dest_id', cfg._utange_point_location(v.get('point') if v.get('point') in ('bar', 'kitchen') else False).id)
        recs = super().create(vals_list)
        recs._notify_managers()
        return recs

    def _notify_managers(self):
        group = self.env.ref('point_of_sale.group_pos_manager', raise_if_not_found=False)
        users = group.users.filtered(lambda u: u.active and not u.share) if group else self.env['res.users']
        users = users.filtered(lambda u: self.env.company in u.company_ids)[:5]
        todo = self.env.ref('mail.mail_activity_data_todo', raise_if_not_found=False)
        for r in self:
            for u in users:
                try:
                    r.activity_schedule(activity_type_id=todo.id if todo else False, user_id=u.id,
                                        summary='Approve requisition %s' % r.name,
                                        note='%s asks for %d item(s) from %s.' % (
                                            r.employee_id.name or 'The bar', len(r.line_ids), r.location_src_id.display_name))
                except Exception:
                    pass

    def _picking_type(self):
        self.ensure_one()
        wh = self.location_src_id.warehouse_id or self.config_id.picking_type_id.warehouse_id
        ptype = wh.int_type_id if wh else False
        if not ptype:
            ptype = self.env['stock.picking.type'].search(
                [('code', '=', 'internal'), ('company_id', 'in', (self.company_id.id, False))], limit=1)
        if not ptype:
            raise UserError('No internal transfer operation type found. Enable Storage Locations in Inventory settings.')
        return ptype

    def _check_approver(self):
        u = self.env.user
        if not (u.has_group('point_of_sale.group_pos_manager') or u.has_group('stock.group_stock_manager')):
            raise UserError('Only a manager (Point of Sale or Inventory manager) can approve or reject requisitions.')

    def action_approve(self):
        self._check_approver()
        for r in self:
            if r.state != 'submitted':
                raise UserError('%s is not waiting for approval.' % r.name)
            lines = r.line_ids.filtered(lambda l: l.qty > 0)
            if not lines:
                raise UserError('%s has no items.' % r.name)
            if r.location_src_id == r.location_dest_id:
                raise UserError('The store and the bar are the same location. Set "Requisitions from (store)" '
                                'on the Point of Sale (Point of Sale > Utange > Handheld settings).')
            ptype = r._picking_type()
            picking = self.env['stock.picking'].sudo().create({
                'picking_type_id': ptype.id,
                'location_id': r.location_src_id.id,
                'location_dest_id': r.location_dest_id.id,
                'origin': r.name,
                'utange_requisition_id': r.id,
                'move_ids': [(0, 0, {
                    'name': l.product_id.display_name,
                    'product_id': l.product_id.id,
                    'product_uom_qty': l.qty,
                    'product_uom': l.product_id.uom_id.id,
                    'location_id': r.location_src_id.id,
                    'location_dest_id': r.location_dest_id.id,
                }) for l in lines],
            })
            picking.action_confirm()
            picking.action_assign()
            r.write({'state': 'approved', 'picking_id': picking.id,
                     'approved_by_id': self.env.user.id, 'approved_date': fields.Datetime.now()})
            r.activity_ids.action_feedback(feedback='Approved')
            if r.config_id.utange_auto_issue:
                r._issue_now(picking)
            else:
                r.message_post(body='Approved. Transfer %s created for the store.' % picking.name)
        return True

    def _issue_now(self, picking):
        """Moves the stock at once: as much of each item as the main store has."""
        self.ensure_one()
        picking = picking.sudo()
        short = []
        for m in picking.move_ids:
            have = m.product_id.with_context(location=picking.location_id.id).qty_available
            give = max(0.0, min(m.product_uom_qty, have))
            if give < m.product_uom_qty:
                short.append('%s: store has %g, asked %g' % (m.product_id.display_name, max(have, 0), m.product_uom_qty))
            m.quantity = give
            m.picked = True
        if not any(m.quantity > 0 for m in picking.move_ids):
            raise UserError('The main store (%s) has none of these items. Receive stock first (purchase), '
                            'or move it in Inventory.' % picking.location_id.display_name)
        picking.move_ids.filtered(lambda m: m.quantity <= 0)._action_cancel()
        picking.with_context(skip_backorder=True, picking_ids_not_to_backorder=picking.ids,
                             skip_sms=True, skip_immediate=True).button_validate()
        self.message_post(body='Approved and issued: %s moved %s → %s.%s' % (
            picking.name, picking.location_id.display_name, picking.location_dest_id.display_name,
            ('<br/>Short: ' + '; '.join(short)) if short else ''))

    def action_reject(self):
        self._check_approver()
        for r in self:
            if r.state not in ('submitted', 'approved'):
                raise UserError('%s cannot be rejected now.' % r.name)
            if r.picking_id and r.picking_id.state not in ('done', 'cancel'):
                r.picking_id.sudo().action_cancel()
            r.state = 'rejected'
            r.activity_ids.action_feedback(feedback='Rejected')
        return True

    def action_cancel(self):
        for r in self:
            if r.state != 'submitted':
                raise UserError('Only a requisition waiting for approval can be cancelled.')
            r.state = 'cancel'
            r.activity_ids.unlink()
        return True

    def action_view_picking(self):
        self.ensure_one()
        return {'type': 'ir.actions.act_window', 'res_model': 'stock.picking', 'res_id': self.picking_id.id,
                'view_mode': 'form', 'target': 'current'}

    def _utange_issued(self):
        """Called when the transfer is validated."""
        for r in self:
            picking = r.picking_id
            if not picking or picking.state != 'done':
                continue
            for l in r.line_ids:
                moves = picking.move_ids.filtered(lambda m: m.product_id == l.product_id and m.state == 'done')
                l.qty_issued = sum(moves.mapped('quantity'))
            r.state = 'done'
            r.message_post(body='Issued by the store (%s).' % picking.name)


class UtangeRequisitionLine(models.Model):
    _name = 'utange.requisition.line'
    _description = 'Requisition item'

    requisition_id = fields.Many2one('utange.requisition', required=True, ondelete='cascade', index=True)
    product_id = fields.Many2one('product.product', 'Item', required=True)
    uom_id = fields.Many2one(related='product_id.uom_id', string='Unit')
    qty = fields.Float('Requested', digits='Product Unit of Measure', default=1)
    qty_issued = fields.Float('Issued', digits='Product Unit of Measure', readonly=True)
    bar_qty = fields.Float('In bar (when asked)', digits='Product Unit of Measure', readonly=True)
    store_qty = fields.Float('In store (when asked)', digits='Product Unit of Measure', readonly=True)
    note = fields.Char()
