from odoo import api, fields, models

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
    utange_sheet_categ_ids = fields.Many2many(
        'pos.category', 'utange_sheet_pos_categ_rel', 'config_id', 'categ_id', string='Stock sheet categories',
        help='Only products of these POS categories are on the stock sheet. Empty: all stock-tracked POS products.')

    # ------------------------------------------------------------------
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
