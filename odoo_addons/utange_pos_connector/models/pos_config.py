from odoo import fields, models


class PosConfig(models.Model):
    _inherit = 'pos.config'

    utange_store_location_id = fields.Many2one(
        'stock.location', string='Requisitions from (store)', domain=[('usage', '=', 'internal')],
        help='Where requisitions from this POS are issued from (e.g. Main Store). '
             'Empty: the stock location of the warehouse.')
    utange_require_sheet = fields.Boolean(
        'Count stock to open a shift', default=True,
        help='The handheld asks the cashier to count every item before the session opens.')
    utange_count_at_close = fields.Boolean(
        'Count stock to close a shift', default=True,
        help='The handheld asks for the closing count before the session closes.')
    utange_sheet_categ_ids = fields.Many2many(
        'pos.category', 'utange_sheet_pos_categ_rel', 'config_id', 'categ_id', string='Stock sheet categories',
        help='Only products of these POS categories are on the stock sheet. Empty: all stock-tracked POS products '
             '(or the POS restricted categories, if set).')

    def _utange_location(self):
        self.ensure_one()
        return self.picking_type_id.default_location_src_id

    def _utange_store_location(self):
        self.ensure_one()
        if self.utange_store_location_id:
            return self.utange_store_location_id
        wh = self.picking_type_id.warehouse_id
        return wh.lot_stock_id if wh else self.env['stock.location']

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
