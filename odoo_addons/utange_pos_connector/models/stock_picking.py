from odoo import api, fields, models


class StockPicking(models.Model):
    _inherit = 'stock.picking'

    utange_requisition_id = fields.Many2one('utange.requisition', 'Requisition', index=True, copy=False, readonly=True)

    def _action_done(self):
        res = super()._action_done()
        self.filtered(lambda p: p.state == 'done' and p.utange_requisition_id).utange_requisition_id.sudo()._utange_issued()
        return res

    # ------------------------------------------------------------------
    # POS sales: drinks come off the Bar stock, food off the Kitchen stock.
    # Odoo makes one picking from the POS source location; here the lines are
    # split by the location of each item (POS category Bar / Kitchen).
    # ------------------------------------------------------------------
    @api.model
    def _create_picking_from_pos_order_lines(self, location_dest_id, lines, picking_type, partner=False):
        if self.env.context.get('utange_src_location') or not lines:
            return super()._create_picking_from_pos_order_lines(location_dest_id, lines, picking_type, partner)
        config = lines.order_id.session_id.config_id[:1] or lines.order_id.config_id[:1]
        if not config or not (config.utange_bar_location_id or config.utange_kitchen_location_id):
            return super()._create_picking_from_pos_order_lines(location_dest_id, lines, picking_type, partner)
        default = picking_type.default_location_src_id
        groups = {}
        for line in lines:
            loc = config._utange_location_for(line.product_id) or default
            groups.setdefault(loc.id, self.env['pos.order.line'])
            groups[loc.id] |= line
        pickings = self.env['stock.picking']
        for loc_id, group in groups.items():
            if loc_id == default.id:
                pickings |= super()._create_picking_from_pos_order_lines(location_dest_id, group, picking_type, partner)
            else:
                pickings |= super(StockPicking, self.with_context(utange_src_location=loc_id)) \
                    ._create_picking_from_pos_order_lines(location_dest_id, group, picking_type, partner)
        return pickings

    def _prepare_picking_vals(self, partner, picking_type, location_id, location_dest_id):
        vals = super()._prepare_picking_vals(partner, picking_type, location_id, location_dest_id)
        loc = self.env.context.get('utange_src_location')
        if loc:
            src = self.env['stock.location'].browse(location_id)
            if src.usage == 'internal':
                vals['location_id'] = loc  # sale: out of the bar / kitchen
            else:
                vals['location_dest_id'] = loc  # refund: back into the bar / kitchen
        return vals
