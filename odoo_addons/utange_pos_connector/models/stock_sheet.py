from odoo import api, fields, models
from odoo.exceptions import UserError
from odoo.tools import float_is_zero

APPROVAL = [('none', 'No differences'), ('pending', 'Waiting for manager'),
            ('approved', 'Approved'), ('rejected', 'Rejected')]
ADJ_NAME = 'Utange stock count'


class UtangeStockSheet(models.Model):
    """One shift of one POS: the stock counted at opening, what came in and went
    out during the shift, what was sold, and the count at closing - the same
    columns as the paper stock book."""
    _name = 'utange.stock.sheet'
    _description = 'Shift stock sheet'
    _inherit = ['mail.thread', 'mail.activity.mixin']
    _order = 'open_date desc, id desc'

    name = fields.Char(required=True, default='/', copy=False, readonly=True)
    config_id = fields.Many2one('pos.config', 'Point of Sale', required=True, readonly=True, index=True)
    session_id = fields.Many2one('pos.session', 'Session', readonly=True, index=True)
    location_id = fields.Many2one('stock.location', 'Stock location', required=True, readonly=True)
    company_id = fields.Many2one('res.company', default=lambda s: s.env.company, readonly=True)
    currency_id = fields.Many2one(related='company_id.currency_id')
    state = fields.Selection([('draft', 'Opening count'), ('open', 'Shift open'), ('closing', 'Closing count'),
                              ('closed', 'Closed')], default='open',
                             required=True, tracking=True, readonly=True)
    open_date = fields.Datetime('Opened', readonly=True, default=fields.Datetime.now)
    close_date = fields.Datetime('Closed', readonly=True)
    open_employee_id = fields.Many2one('hr.employee', 'Opening count by', readonly=True)
    close_employee_id = fields.Many2one('hr.employee', 'Closing count by', readonly=True)
    opened_outside = fields.Boolean('Opened outside the handheld', readonly=True,
                                    help='The session was opened without a count; the opening figures are worked out by Odoo.')
    line_ids = fields.One2many('utange.stock.sheet.line', 'sheet_id', 'Items')
    close_confirmed = fields.Boolean('Closing count confirmed', readonly=True, copy=False)
    open_user_id = fields.Many2one('res.users', 'Opening confirmed by (Odoo)', readonly=True)
    close_user_id = fields.Many2one('res.users', 'Closing confirmed by (Odoo)', readonly=True)
    note = fields.Text('Notes')
    utange_can_approve = fields.Boolean(compute='_compute_can_approve')
    open_approval = fields.Selection(APPROVAL, 'Opening approval', default='none', readonly=True, tracking=True)
    close_approval = fields.Selection(APPROVAL, 'Closing approval', default='none', readonly=True, tracking=True)
    open_approved_by = fields.Char('Opening approved by', readonly=True)
    close_approved_by = fields.Char('Closing approved by', readonly=True)
    open_reason = fields.Char('Opening reason', readonly=True)
    close_reason = fields.Char('Closing reason', readonly=True)
    open_diff_count = fields.Integer('Opening differences', compute='_compute_totals', store=True)
    close_diff_count = fields.Integer('Closing differences', compute='_compute_totals', store=True)
    amount_total = fields.Monetary('Sales', compute='_compute_totals', store=True)
    close_diff_value = fields.Monetary('Closing variance (value)', compute='_compute_totals', store=True,
                                       help='Closing differences at selling price. Negative = items missing.')

    @api.depends('line_ids.open_diff', 'line_ids.close_diff', 'line_ids.amount', 'line_ids.price')
    def _compute_totals(self):
        for s in self:
            s.open_diff_count = len(s.line_ids.filtered(lambda l: not float_is_zero(l.open_diff, precision_digits=3)))
            s.close_diff_count = len(s.line_ids.filtered(lambda l: l.closed and not float_is_zero(l.close_diff, precision_digits=3)))
            s.amount_total = sum(s.line_ids.mapped('amount'))
            s.close_diff_value = sum(l.close_diff * l.price for l in s.line_ids if l.closed)

    def _compute_can_approve(self):
        can = self.env.user._utange_can_approve()
        for s in self:
            s.utange_can_approve = can

    def _approvers_to_notify(self):
        users = self.env['res.users'].sudo()
        if users._utange_approvers_chosen():
            chosen = users.search([('utange_approver', '=', True), ('share', '=', False)])
            return chosen | self.env['hr.employee'].sudo().search([('utange_approver', '=', True)]).user_id
        group = self.env.ref('point_of_sale.group_pos_manager', raise_if_not_found=False)
        return group.users.filtered(lambda u: u.active and not u.share) if group else users

    @api.model_create_multi
    def create(self, vals_list):
        for v in vals_list:
            if v.get('name', '/') == '/':
                v['name'] = self.env['ir.sequence'].next_by_code('utange.stock.sheet') or '/'
        return super().create(vals_list)

    # ------------------------------------------------------------------
    @api.model
    def _price_incl(self, product, config):
        taxes = product.taxes_id.filtered(lambda t: t.company_id == config.company_id) or product.taxes_id
        price = product.lst_price
        if taxes:
            return taxes.compute_all(price, config.company_id.currency_id, 1, product=product)['total_included']
        return price

    @api.model
    def _on_hand(self, products, location):
        return {p.id: p.qty_available for p in products.with_context(location=location.id)}

    @api.model
    def _on_hand_for(self, config, products):
        """{product_id: (location, qty)} - each product at its own location (bar / kitchen / POS)."""
        out = {}
        for p in products:
            loc = config._utange_location_for(p)
            out[p.id] = (loc, p.with_context(location=loc.id).qty_available)
        return out

    @api.model
    def _opening_items(self, config):
        order = {'bar': 0, 'kitchen': 1}
        products = config._utange_sheet_products().sorted(
            lambda p: (order.get(p.product_tmpl_id._utange_point(), 2), p.display_name))
        on_hand = self._on_hand_for(config, products)
        last = self.search([('config_id', '=', config.id), ('state', '=', 'closed')], order='close_date desc, id desc', limit=1)
        last_count = {l.product_id.id: l.counted_close for l in last.line_ids if l.closed} if last else {}
        return [{'product_id': p.id, 'name': p.display_name, 'uom': p.uom_id.name or '',
                 'point': config._utange_point_label(p.product_tmpl_id._utange_point()),
                 'ref': on_hand.get(p.id, (None, 0.0))[1], 'last_close': last_count.get(p.id)} for p in products]

    def _adjust_stock(self, phase):
        """Approved differences: the stock at each line's location is moved by the difference
        (opening: counted - Odoo; closing: counted - expected), so Odoo matches the shelf."""
        Move = self.env['stock.move'].sudo()
        for sheet in self.sudo():
            if not sheet.config_id.utange_apply_open_count:
                continue
            later = self.search([('config_id', '=', sheet.config_id.id), ('id', '>', sheet.id), ('state', '!=', 'draft')], limit=1)
            if later:
                # a newer count (e.g. the next shift's opening) already set the real figures: do not correct twice
                sheet.message_post(body='Approved without changing the stock: the newer count %s already '
                                        'reflects the shelf.' % later.name)
                continue
            done = []
            for l in sheet.line_ids:
                if phase == 'close' and not l.closed:
                    continue
                diff = (l.counted_open - l.system_open) if phase == 'open' else (l.counted_close - l.expected_close)
                if float_is_zero(diff, precision_digits=4) or not l.location_id or l.product_id.type != 'product':
                    continue
                p = l.product_id
                inv = p.with_company(sheet.company_id).property_stock_inventory
                if not inv:
                    continue
                src, dst = (inv, l.location_id) if diff > 0 else (l.location_id, inv)
                m = Move.create({
                    'name': '%s %s' % (ADJ_NAME, sheet.name), 'origin': sheet.name, 'product_id': p.id,
                    'product_uom': p.uom_id.id, 'product_uom_qty': abs(diff), 'location_id': src.id,
                    'location_dest_id': dst.id, 'company_id': sheet.company_id.id, 'is_inventory': True,
                })
                m._action_confirm()
                m.quantity = abs(diff)
                m.picked = True
                m._action_done()
                done.append('%s %+g' % (p.display_name, diff))
            if done:
                sheet.message_post(body='Stock corrected to the %s count: %s.' % (
                    'opening' if phase == 'open' else 'closing', ', '.join(done)))

    # ------------------------------------------------------------------
    # Manager approval of count differences
    # ------------------------------------------------------------------
    def _diff_text(self, phase):
        self.ensure_one()
        if phase == 'open':
            bad = self.line_ids.filtered(lambda l: not float_is_zero(l.open_diff, precision_digits=3))
            return bad, ', '.join('%s %+g' % (l.product_id.display_name, l.open_diff) for l in bad[:15])
        bad = self.line_ids.filtered(lambda l: l.closed and not float_is_zero(l.close_diff, precision_digits=3))
        return bad, ', '.join('%s %+g' % (l.product_id.display_name, l.close_diff) for l in bad[:15])

    def _settle(self, phase, by=None, reason=''):
        """After a count: no differences -> nothing to approve; a manager there (PIN / signed in as manager)
        -> approved now; else waiting for a manager (Manager app or Odoo). Returns the approval state."""
        self.ensure_one()
        sheet = self.sudo()
        bad, text = sheet._diff_text(phase)
        reason = (reason or '').strip()[:250]
        sheet.write({'%s_reason' % phase: reason})
        if not bad:
            sheet.write({'%s_approval' % phase: 'none'})
            return 'none'
        label = 'Opening' if phase == 'open' else 'Closing'
        extra = ' Value at selling price: %.0f.' % sheet.close_diff_value if phase == 'close' else ''
        sheet.message_post(body='%s differences: %s.%s%s' % (label, text, extra, (' Reason: %s' % reason) if reason else ''))
        if by:
            sheet._approve(phase, by)
            return 'approved'
        sheet.write({'%s_approval' % phase: 'pending'})
        todo = self.env.ref('mail.mail_activity_data_todo', raise_if_not_found=False)
        for u in sheet._approvers_to_notify()[:8]:
            try:
                sheet.activity_schedule(activity_type_id=todo.id if todo else False, user_id=u.id,
                                        summary='Approve %s count %s: %d items' % (label.lower(), sheet.name, len(bad)),
                                        note=text + ((' - ' + reason) if reason else ''))
            except Exception:
                pass
        return 'pending'

    def _approve(self, phase, by):
        for sheet in self.sudo():
            if sheet['%s_approval' % phase] == 'approved':
                continue
            sheet._adjust_stock(phase)
            sheet.write({'%s_approval' % phase: 'approved', '%s_approved_by' % phase: by})
            sheet.message_post(body='%s differences approved by %s.' % ('Opening' if phase == 'open' else 'Closing', by))
            sheet.activity_ids.filtered(lambda a: ('%s count' % ('opening' if phase == 'open' else 'closing'))
                                        in (a.summary or '')).action_feedback(feedback='Approved by %s' % by)

    def _reject(self, phase, by):
        for sheet in self.sudo():
            if sheet['%s_approval' % phase] != 'pending':
                continue
            sheet.write({'%s_approval' % phase: 'rejected', '%s_approved_by' % phase: by})
            sheet.message_post(body='%s differences rejected by %s: Odoo stock not changed; the difference stays on this shift.'
                                    % ('Opening' if phase == 'open' else 'Closing', by))
            sheet.activity_ids.filtered(lambda a: ('%s count' % ('opening' if phase == 'open' else 'closing'))
                                        in (a.summary or '')).action_feedback(feedback='Rejected by %s' % by)

    def _check_manager(self):
        if not self.env.user._utange_can_approve():
            raise UserError('You are not allowed to approve count differences. '
                            'Tick "Utange: can approve" on the user (Settings > Users).')

    def action_approve_open(self):
        self._check_manager()
        self.filtered(lambda s: s.open_approval == 'pending')._approve('open', self.env.user.name)

    def action_reject_open(self):
        self._check_manager()
        self._reject('open', self.env.user.name)

    def action_approve_close(self):
        self._check_manager()
        self.filtered(lambda s: s.close_approval == 'pending')._approve('close', self.env.user.name)

    def action_reject_close(self):
        self._check_manager()
        self._reject('close', self.env.user.name)

    @api.model
    def _done_qty(self, move):
        qty = move.quantity if 'quantity' in move._fields else move.quantity_done
        return move.product_uom._compute_quantity(qty, move.product_id.uom_id) if move.product_uom else qty

    def _refresh_movements(self, until=None):
        """Received / sent out (done stock moves other than POS) and sold (POS lines of the session)."""
        for sheet in self.sudo():
            until = until or sheet.close_date or fields.Datetime.now()
            lines = sheet.line_ids
            pids = lines.product_id.ids
            if not pids:
                continue
            sold, amount = {}, {}
            if sheet.session_id:
                pos_lines = self.env['pos.order.line'].sudo().search([
                    ('order_id.session_id', '=', sheet.session_id.id),
                    ('order_id.state', 'in', ('paid', 'done', 'invoiced')),
                    ('order_id.date_order', '>=', sheet.open_date),
                    ('product_id', 'in', pids)])
                for pl in pos_lines:
                    sold[pl.product_id.id] = sold.get(pl.product_id.id, 0.0) + pl.qty
                    amount[pl.product_id.id] = amount.get(pl.product_id.id, 0.0) + pl.price_subtotal_incl
            dom = [('state', '=', 'done'), ('date', '>=', sheet.open_date), ('date', '<=', until),
                   ('name', 'not like', ADJ_NAME)]
            pos_type = sheet.config_id.picking_type_id
            if pos_type:
                dom.append(('picking_type_id', '!=', pos_type.id))
                if pos_type.return_picking_type_id:
                    dom.append(('picking_type_id', '!=', pos_type.return_picking_type_id.id))
            Move = self.env['stock.move'].sudo()
            Loc = self.env['stock.location'].sudo()
            received, sent = {}, {}
            for loc in lines.mapped(lambda l: l.location_id or sheet.location_id):
                lpids = lines.filtered(lambda l, loc=loc: (l.location_id or sheet.location_id) == loc).product_id.ids
                inside = Loc.search([('id', 'child_of', loc.id)]).ids
                d = dom + [('product_id', 'in', lpids)]
                for m in Move.search(d + [('location_dest_id', 'in', inside), ('location_id', 'not in', inside)]):
                    received[m.product_id.id] = received.get(m.product_id.id, 0.0) + self._done_qty(m)
                for m in Move.search(d + [('location_id', 'in', inside), ('location_dest_id', 'not in', inside)]):
                    sent[m.product_id.id] = sent.get(m.product_id.id, 0.0) + self._done_qty(m)
            for l in lines:
                pid = l.product_id.id
                l.write({'received': received.get(pid, 0.0), 'sent_out': sent.get(pid, 0.0),
                         'sold': sold.get(pid, 0.0), 'amount': amount.get(pid, 0.0)})

    @api.model
    def _start(self, config, session, counts, employee=None, outside=False, state='open'):
        """Creates the sheet of a shift. counts: {product_id: counted qty}; missing = system quantity."""
        location = config._utange_location()
        products = config._utange_sheet_products()
        on_hand = self._on_hand_for(config, products)
        sheet = self.sudo().create({
            'config_id': config.id,
            'session_id': session.id if session else False,
            'location_id': location.id,
            'open_employee_id': employee.id if employee else False,
            'open_date': (session.start_at if outside and session and session.start_at else fields.Datetime.now()),
            'opened_outside': outside,
            'state': state,
        })
        lines = []
        order = {'bar': 0, 'kitchen': 1}
        products = products.sorted(lambda p: (order.get(p.product_tmpl_id._utange_point(), 2), p.display_name))
        for seq, p in enumerate(products):
            loc, system = on_hand.get(p.id, (location, 0.0))
            counted = counts.get(p.id, system) if counts else system
            lines.append({'sheet_id': sheet.id, 'sequence': seq, 'product_id': p.id, 'location_id': loc.id,
                          'price': self._price_incl(p, config), 'system_open': system, 'counted_open': counted})
        self.env['utange.stock.sheet.line'].sudo().create(lines)
        if outside:
            # Opened in Odoo POS without a count: opening = on hand now, less what came in, plus what went out
            # (POS sales are only taken off stock when the session closes, unless stock is updated in real time).
            sheet._refresh_movements()
            real_time = not config._utange_update_at_closing()
            for l in sheet.line_ids:
                opening = l.system_open - l.received + l.sent_out + (l.sold if real_time else 0.0)
                l.write({'system_open': opening, 'counted_open': opening})
            sheet.message_post(body='The session was opened without a count on the handheld: opening figures worked out by Odoo.')
        return sheet

    def _finish(self, counts, employee=None):
        """Closing count. counts: {product_id: counted qty}; missing = expected."""
        now = fields.Datetime.now()
        for sheet in self.sudo():
            sheet._refresh_movements(until=now)
            for l in sheet.line_ids:
                l.write({'counted_close': counts.get(l.product_id.id, l.expected_close) if counts else l.expected_close,
                         'closed': True})
            sheet.write({'close_date': now, 'close_employee_id': employee.id if employee else False, 'close_confirmed': True})

    def _notify_variance(self):
        """Closing differences: a to-do for the POS managers and a note on the sheet."""
        for sheet in self:
            bad = sheet.line_ids.filtered(lambda l: l.closed and abs(l.close_diff) > 0.0001)
            if not bad:
                continue
            text = ', '.join('%s %+g' % (l.product_id.display_name, l.close_diff) for l in bad[:15])
            sheet.message_post(body='Closing variance: %s. Value at selling price: %.0f.' % (text, sheet.close_diff_value))
            group = self.env.ref('point_of_sale.group_pos_manager', raise_if_not_found=False)
            todo = self.env.ref('mail.mail_activity_data_todo', raise_if_not_found=False)
            for u in (group.users.filtered(lambda u: u.active and not u.share)[:5] if group else []):
                try:
                    sheet.activity_schedule(activity_type_id=todo.id if todo else False, user_id=u.id,
                                            summary='Stock variance %s: %d items' % (sheet.name, len(bad)), note=text)
                except Exception:
                    pass

    # ------------------------------------------------------------------
    # Counting in Odoo (same rules as the handheld)
    # ------------------------------------------------------------------
    def action_confirm_open(self):
        for s in self:
            if s.state != 'draft':
                continue
            for l in s.line_ids:  # what Odoo has right now
                if l.location_id:
                    l.system_open = l.product_id.with_context(location=l.location_id.id).qty_available
            s.write({'state': 'open', 'open_date': fields.Datetime.now(), 'open_user_id': self.env.user.id})
            s.message_post(body='Opening count confirmed in Odoo: %d differences.' % s.open_diff_count)
            s._settle('open', self.env.user.name if self.env.user._utange_can_approve() else None)
        return True

    def action_start_close(self):
        for s in self:
            if s.state != 'open':
                continue
            s._refresh_movements()
            for l in s.line_ids:
                l.counted_close = l.expected_close
            s.state = 'closing'
        return True

    def action_confirm_close(self):
        now = fields.Datetime.now()
        for s in self:
            if s.state != 'closing' or s.close_confirmed:
                continue
            counts = {l.product_id.id: l.counted_close for l in s.line_ids}
            s._refresh_movements(until=now)
            for l in s.line_ids:
                l.write({'counted_close': counts.get(l.product_id.id, l.expected_close), 'closed': True})
            s.write({'close_date': now, 'close_confirmed': True, 'close_user_id': self.env.user.id})
            s._settle('close', self.env.user.name if self.env.user._utange_can_approve() else None)
            if not s.session_id or s.session_id.state == 'closed':
                s.state = 'closed'
        return True

    def action_reopen_close_count(self):
        for s in self.filtered(lambda x: x.state == 'closing' and x.close_confirmed and x.session_id.state != 'closed'):
            if s.close_approval == 'approved':
                raise UserError('The closing differences were already approved and the stock corrected; it cannot be recounted.')
            s.activity_ids.filtered(lambda a: 'closing count' in (a.summary or '')).unlink()
            s.write({'close_confirmed': False, 'close_approval': 'none'})
            s.line_ids.write({'closed': False})
        return True

    def action_refresh(self):
        self.filtered(lambda s: s.state == 'open')._refresh_movements()

    def action_print(self):
        return self.env.ref('utange_pos_connector.action_report_stock_sheet').report_action(self)


class UtangeStockSheetLine(models.Model):
    _name = 'utange.stock.sheet.line'
    _description = 'Stock sheet item'
    _order = 'sequence, id'

    sheet_id = fields.Many2one('utange.stock.sheet', required=True, ondelete='cascade', index=True)
    sequence = fields.Integer()
    product_id = fields.Many2one('product.product', 'Item', required=True)
    location_id = fields.Many2one('stock.location', 'Stock', help='Bar, kitchen or POS stock this item is sold from.')
    point = fields.Char('Point', compute='_compute_point')
    uom_id = fields.Many2one(related='product_id.uom_id', string='Unit')
    price = fields.Float('Selling price', digits='Product Price')
    system_open = fields.Float('System opening', digits='Product Unit of Measure')
    counted_open = fields.Float('Opening count', digits='Product Unit of Measure')
    open_diff = fields.Float('Opening difference', compute='_compute_diffs', store=True, digits='Product Unit of Measure')
    received = fields.Float('Received', digits='Product Unit of Measure', help='Transfers and purchases into the bar during the shift.')
    sent_out = fields.Float('Sent out', digits='Product Unit of Measure', help='Transfers out of the bar during the shift (not sales).')
    sold = fields.Float('Sold', digits='Product Unit of Measure')
    amount = fields.Float('Sales amount', digits='Product Price')
    expected_close = fields.Float('Expected closing', compute='_compute_diffs', store=True, digits='Product Unit of Measure')
    counted_close = fields.Float('Closing count', digits='Product Unit of Measure')
    closed = fields.Boolean('Counted at closing')
    close_diff = fields.Float('Closing difference', compute='_compute_diffs', store=True, digits='Product Unit of Measure')

    @api.depends('location_id', 'sheet_id.config_id')
    def _compute_point(self):
        for l in self:
            cfg = l.sheet_id.config_id
            l.point = ('Bar' if cfg.utange_bar_location_id and l.location_id == cfg.utange_bar_location_id else
                       'Kitchen' if cfg.utange_kitchen_location_id and l.location_id == cfg.utange_kitchen_location_id else
                       (l.location_id.display_name or ''))

    @api.depends('system_open', 'counted_open', 'received', 'sent_out', 'sold', 'counted_close', 'closed')
    def _compute_diffs(self):
        for l in self:
            l.open_diff = l.counted_open - l.system_open
            l.expected_close = l.counted_open + l.received - l.sent_out - l.sold
            l.close_diff = (l.counted_close - l.expected_close) if l.closed else 0.0
