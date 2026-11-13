from odoo import api, fields, models
from odoo.tools import float_is_zero


class UtangeStockSheet(models.Model):
    """One shift of one POS: the stock counted at opening, what came in and went
    out during the shift, what was sold, and the count at closing - the same
    columns as the paper stock book."""
    _name = 'utange.stock.sheet'
    _description = 'Shift stock sheet'
    _inherit = ['mail.thread']
    _order = 'open_date desc, id desc'

    name = fields.Char(required=True, default='/', copy=False, readonly=True)
    config_id = fields.Many2one('pos.config', 'Point of Sale', required=True, readonly=True, index=True)
    session_id = fields.Many2one('pos.session', 'Session', readonly=True, index=True)
    location_id = fields.Many2one('stock.location', 'Stock location', required=True, readonly=True)
    company_id = fields.Many2one('res.company', default=lambda s: s.env.company, readonly=True)
    currency_id = fields.Many2one(related='company_id.currency_id')
    state = fields.Selection([('open', 'Shift open'), ('closed', 'Closed')], default='open',
                             required=True, tracking=True, readonly=True)
    open_date = fields.Datetime('Opened', readonly=True, default=fields.Datetime.now)
    close_date = fields.Datetime('Closed', readonly=True)
    open_employee_id = fields.Many2one('hr.employee', 'Opening count by', readonly=True)
    close_employee_id = fields.Many2one('hr.employee', 'Closing count by', readonly=True)
    opened_outside = fields.Boolean('Opened outside the handheld', readonly=True,
                                    help='The session was opened without a count; the opening figures are worked out by Odoo.')
    line_ids = fields.One2many('utange.stock.sheet.line', 'sheet_id', 'Items', readonly=True)
    note = fields.Text('Notes')
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
                    ('product_id', 'in', pids)])
                for pl in pos_lines:
                    sold[pl.product_id.id] = sold.get(pl.product_id.id, 0.0) + pl.qty
                    amount[pl.product_id.id] = amount.get(pl.product_id.id, 0.0) + pl.price_subtotal_incl
            dom = [('state', '=', 'done'), ('date', '>=', sheet.open_date), ('date', '<=', until)]
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
    def _start(self, config, session, counts, employee=None, outside=False):
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
            sheet.write({'close_date': now, 'close_employee_id': employee.id if employee else False})

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
