import time

from odoo import api, fields, models
from odoo.tools import consteq

POINTS = [('bar', 'Bar'), ('kitchen', 'Kitchen')]


class PosCategory(models.Model):
    _inherit = 'pos.category'

    utange_stock_point = fields.Selection(
        POINTS, string='Sold from (stock)',
        help='Items of this POS category are taken off the Bar stock or the Kitchen stock when sold. '
             'Sub-categories without a value use their parent\'s.')

    def _utange_point(self):
        c = self
        while c:
            if c.utange_stock_point:
                return c.utange_stock_point
            c = c.parent_id
        return False


class ProductTemplate(models.Model):
    _inherit = 'product.template'

    utange_stock_point = fields.Selection(
        POINTS + [('main', 'POS default location')], string='Sold from (stock)',
        help='Empty: as set on the POS category (Bar or Kitchen).')

    def _utange_point(self):
        self.ensure_one()
        if self.utange_stock_point:
            return False if self.utange_stock_point == 'main' else self.utange_stock_point
        for c in self.pos_categ_ids:
            p = c._utange_point()
            if p:
                return p
        return False


class PosConfig(models.Model):
    _inherit = 'pos.config'

    utange_store_location_id = fields.Many2one(
        'stock.location', string='Main store', domain=[('usage', '=', 'internal')],
        help='Where everything is kept. Requisitions for the bar and the kitchen are issued from here; '
             'purchases are received here.')
    utange_bar_location_id = fields.Many2one(
        'stock.location', string='Bar stock', domain=[('usage', '=', 'internal')],
        help='Drinks (categories set to Bar) are taken off this location when sold.')
    utange_kitchen_location_id = fields.Many2one(
        'stock.location', string='Kitchen stock', domain=[('usage', '=', 'internal')],
        help='Food (categories set to Kitchen) is taken off this location when sold.')
    utange_require_sheet = fields.Boolean(
        'Count stock to open a shift', default=True,
        help='The handheld asks the cashier to count every item before the session opens.')
    utange_count_at_close = fields.Boolean(
        'Count stock to close a shift', default=True,
        help='The handheld asks for the closing count before the session closes.')
    utange_block_zero = fields.Boolean(
        'Do not sell items with no stock', default=True,
        help='The handheld refuses a sale when the bar or kitchen does not have enough of a stock-tracked item.')
    utange_auto_issue = fields.Boolean(
        'Approving a requisition moves the stock', default=True,
        help='On approval the transfer from the main store is validated at once (as much as the store has).')
    utange_apply_open_count = fields.Boolean(
        'Approved counts correct the stock', default=True,
        help='When a manager approves count differences (e.g. Odoo says 2 sodas, the shelf has 1), the bar/kitchen '
             'stock is corrected to what was counted (an inventory adjustment). The difference stays on the stock sheet.')
    utange_sheet_categ_ids = fields.Many2many(
        'pos.category', 'utange_sheet_pos_categ_rel', 'config_id', 'categ_id', string='Stock sheet categories',
        help='Only products of these POS categories are on the stock sheet. Empty: all stock-tracked POS products.')

    # ------------------------------------------------------------------
    def action_utange_count(self):
        """Point of Sale > Handheld > Count stock: the sheet to count now (opening or closing)."""
        self.ensure_one()
        Sheet = self.env['utange.stock.sheet'].sudo()
        session = self.env['pos.session'].sudo().search(
            [('config_id', '=', self.id), ('state', 'in', ('opening_control', 'opened', 'closing_control')),
             ('rescue', '=', False)], order='id desc', limit=1)
        sheet = Sheet
        if session and session.state != 'opening_control':
            sheet = session._utange_sheet()
            if not sheet:
                sheet = Sheet._start(self, session, {}, outside=True)  # opened before the add-on: closing count only
        if not sheet:
            sheet = Sheet.search([('config_id', '=', self.id), ('session_id', '=', False), ('state', 'in', ('draft', 'open'))],
                                 order='id desc', limit=1)
        if not sheet:
            sheet = Sheet._start(self, None, {}, state='draft')
        return {'type': 'ir.actions.act_window', 'res_model': 'utange.stock.sheet', 'res_id': sheet.id,
                'view_mode': 'form', 'target': 'current', 'name': 'Count stock: %s' % self.name}

    # ------------------------------------------------------------------
    # Managers (approve count differences)
    # ------------------------------------------------------------------
    def _utange_managers(self):
        self.ensure_one()
        emps = self.sudo().advanced_employee_ids if 'advanced_employee_ids' in self._fields else self.env['hr.employee']
        group = self.sudo().group_pos_manager_id
        if group:
            emps |= self.env['hr.employee'].sudo().search([
                ('user_id', 'in', group.users.ids), ('company_id', 'in', (self.company_id.id, False))])
        return emps

    def _utange_is_manager(self, employee=None, user=None):
        self.ensure_one()
        if employee:
            return employee in self._utange_managers()
        user = user or self.env.user
        return bool(self.sudo().group_pos_manager_id and user in self.sudo().group_pos_manager_id.users)

    def _utange_manager_by_pin(self, pin):
        """(employee, error). 5 wrong PINs lock it for 5 minutes."""
        self.ensure_one()
        pin = str(pin or '').strip()
        P = self.env['ir.config_parameter'].sudo()
        key = 'utange_pos.manager_pin_fails_%d' % self.id
        fails, until = (P.get_param(key) or '0|0').split('|')
        now = int(time.time())
        if int(until) > now:
            return None, 'Too many wrong manager PINs. Try again in %d min.' % ((int(until) - now) // 60 + 1)
        if len(pin) >= 3:
            for e in self._utange_managers():
                if e.sudo().pin and consteq(pin, e.sudo().pin):
                    P.set_param(key, '0|0')
                    return e, None
        fails = int(fails) + 1
        P.set_param(key, '0|%d' % (now + 300) if fails >= 5 else '%d|0' % fails)
        return None, 'Wrong manager PIN.'

    def utange_check_manager_pin(self, pin):
        """Odoo POS screen: is this a POS manager's PIN?"""
        emp, err = self._utange_manager_by_pin(pin)
        return {'ok': bool(emp), 'name': emp.name if emp else '', 'error': err or ''}

    def utange_pos_stock(self, session_id=False):
        """Odoo POS screen: {product_id: quantity that can be sold} for stock-tracked POS products."""
        self.ensure_one()
        if not self.utange_block_zero:
            return {}
        session = self.env['pos.session'].sudo().browse(session_id).exists() if session_id else None
        return {str(k): v for k, v in self.sudo()._utange_available(self._utange_products(storable=True), session).items()}

    def utange_check_stock(self, session_id, lines):
        """Odoo POS screen, before payment: messages for items there is not enough of."""
        self.ensure_one()
        if not self.utange_block_zero:
            return []
        want = {}
        for l in lines or []:
            try:
                pid, qty = int(l.get('product_id')), float(l.get('qty'))
            except (TypeError, ValueError, AttributeError):
                continue
            want[pid] = want.get(pid, 0.0) + qty
        products = self.env['product.product'].sudo().browse([p for p, q in want.items() if q > 0]).exists()
        session = self.env['pos.session'].sudo().browse(session_id).exists() if session_id else None
        avail = self.sudo()._utange_available(products, session)
        out = []
        for p in products:
            if p.id in avail and want[p.id] > avail[p.id] + 1e-6:
                out.append('%s: %g in %s, order has %g' % (
                    p.display_name, max(avail[p.id], 0), self._utange_location_for(p).display_name, want[p.id]))
        return out

    def _utange_location(self):
        """The POS's own source location (used for items that are neither bar nor kitchen)."""
        self.ensure_one()
        return self.picking_type_id.default_location_src_id

    def _utange_point_location(self, point):
        self.ensure_one()
        if point == 'bar' and self.utange_bar_location_id:
            return self.utange_bar_location_id
        if point == 'kitchen' and self.utange_kitchen_location_id:
            return self.utange_kitchen_location_id
        return self._utange_location()

    def _utange_location_for(self, product):
        self.ensure_one()
        return self._utange_point_location(product.product_tmpl_id._utange_point())

    def _utange_point_label(self, point):
        return dict(POINTS).get(point, 'POS')

    def _utange_store_location(self):
        self.ensure_one()
        if self.utange_store_location_id:
            return self.utange_store_location_id
        wh = self.picking_type_id.warehouse_id
        return wh.lot_stock_id if wh else self.env['stock.location']

    def _utange_points(self):
        """[(point, label, location)] the handheld can request for and count."""
        self.ensure_one()
        out = []
        for p, label in POINTS:
            loc = self._utange_point_location(p)
            if loc and loc not in [x[2] for x in out]:
                out.append((p, label, loc))
        if not out and self._utange_location():
            out.append(('main', 'POS', self._utange_location()))
        return out

    def _utange_categories(self):
        self.ensure_one()
        if 'limit_categories' in self._fields and self.limit_categories and self.iface_available_categ_ids:
            return self.iface_available_categ_ids
        return self.env['pos.category']

    def _utange_products(self, storable=False):
        """POS products of this POS (respecting its restricted categories)."""
        self.ensure_one()
        domain = [('available_in_pos', '=', True), ('sale_ok', '=', True)]
        if storable:
            domain.append(('type', '=', 'product'))
        cats = self._utange_categories()
        if cats:
            domain.append(('pos_categ_ids', 'child_of', cats.ids))
        return self.env['product.product'].sudo().search(domain, order='name', limit=1500)

    def _utange_sheet_products(self):
        self.ensure_one()
        products = self._utange_products(storable=True)
        if self.utange_sheet_categ_ids:
            allowed = self.env['pos.category'].search([('id', 'child_of', self.utange_sheet_categ_ids.ids)])
            products = products.filtered(lambda p: p.pos_categ_ids & allowed)
        return products

    def _utange_update_at_closing(self):
        return (self.company_id.point_of_sale_update_stock_quantities or 'closing') == 'closing'

    def _utange_available(self, products, session=None):
        """{product_id: quantity that can still be sold} for stock-tracked products, at each one's own location.
        When stock is updated at closing, what the open session already sold is taken off."""
        self.ensure_one()
        products = products.filtered(lambda p: p.type == 'product')
        if not products:
            return {}
        by_loc = {}
        for p in products:
            by_loc.setdefault(self._utange_location_for(p), self.env['product.product'])
            by_loc[self._utange_location_for(p)] |= p
        out = {}
        for loc, prods in by_loc.items():
            for p in prods.with_context(location=loc.id):
                out[p.id] = p.qty_available
        if session and self._utange_update_at_closing():
            for line in self.env['pos.order.line'].sudo().search([
                    ('order_id.session_id', '=', session.id), ('product_id', 'in', products.ids),
                    ('order_id.state', 'in', ('paid', 'done', 'invoiced'))]):
                if not line.order_id.picking_ids:
                    out[line.product_id.id] = out.get(line.product_id.id, 0.0) - line.qty
        return out
