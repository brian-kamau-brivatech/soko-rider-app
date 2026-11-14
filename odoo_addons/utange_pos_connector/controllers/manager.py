# -*- coding: utf-8 -*-
"""JSON API for the Utange Manager app (managers' phones).

Managers sign in with their own Odoo user (/web/session/authenticate). Only POS
managers and inventory managers can use it. They see open shifts, sales, the
shift stock sheets (opening vs sold vs closing) and approve or reject requisitions.
"""
from datetime import datetime, time, timedelta

from odoo import fields, http
from odoo.exceptions import UserError
from odoo.http import request


def _err(e):
    return str(e.args[0] if getattr(e, 'args', None) else e)


class UtangeManagerApi(http.Controller):

    def _check(self):
        u = request.env.user
        if not (u.has_group('point_of_sale.group_pos_manager') or u.has_group('stock.group_stock_manager')
                or u._utange_can_approve()):
            return {'ok': False, 'error': 'Only POS or Inventory managers (or users ticked "Utange: can approve") '
                                          'can use the manager app.', 'denied': True}
        return None

    def _local(self, rec, dt):
        return fields.Datetime.to_string(fields.Datetime.context_timestamp(rec, dt)) if dt else ''

    def _day_bounds(self):
        today = fields.Date.context_today(request.env.user)
        start = datetime.combine(today, time.min) - timedelta(hours=3)  # EAT midnight in UTC
        return start, start + timedelta(days=1)

    # ------------------------------------------------------------------
    @http.route('/utange/mgr/me', type='json', auth='user', methods=['POST'], csrf=False)
    def me(self, **kw):
        bad = self._check()
        if bad:
            return bad
        u = request.env.user
        return {'ok': True, 'name': u.name, 'company': request.env.company.name,
                'approve': u._utange_can_approve()}

    @http.route('/utange/mgr/dashboard', type='json', auth='user', methods=['POST'], csrf=False)
    def dashboard(self, **kw):
        bad = self._check()
        if bad:
            return bad
        env = request.env
        Order = env['pos.order'].sudo()
        start, end = self._day_bounds()
        today = Order.search([('date_order', '>=', start), ('date_order', '<', end), ('state', 'in', ('paid', 'done', 'invoiced'))])
        by_method = {}
        for p in today.payment_ids:
            by_method[p.payment_method_id.name] = by_method.get(p.payment_method_id.name, 0) + p.amount
        shifts = []
        for s in env['pos.session'].sudo().search([('state', 'in', ('opened', 'closing_control'))], order='id desc'):
            sheet = env['utange.stock.sheet'].sudo().search([('session_id', '=', s.id)], limit=1)
            orders = s.order_ids.filtered(lambda o: o.state in ('paid', 'done', 'invoiced'))
            shifts.append({'session': s.name, 'config': s.config_id.name, 'since': self._local(s, s.start_at),
                           'user': s.user_id.name or '', 'orders': len(orders),
                           'sales': round(sum(orders.mapped('amount_total')), 2),
                           'sheet_id': sheet.id if sheet else 0, 'sheet': sheet.name if sheet else '',
                           'open_diffs': sheet.open_diff_count if sheet else 0,
                           'outside': bool(sheet.opened_outside) if sheet else True})
        Req = env['utange.requisition'].sudo()
        Sheet = env['utange.stock.sheet'].sudo()
        recent = Sheet.search([('state', '=', 'closed')], order='close_date desc', limit=5)
        return {
            'ok': True,
            'today': {'count': len(today), 'total': round(sum(today.mapped('amount_total')), 2),
                      'by_method': [{'method': k, 'amount': round(v, 2)} for k, v in sorted(by_method.items(), key=lambda x: -x[1])]},
            'shifts': shifts,
            'to_approve': Req.search_count([('state', '=', 'submitted')]),
            'to_issue': Req.search_count([('state', '=', 'approved')]),
            'counts_to_approve': Sheet.search_count(['|', ('open_approval', '=', 'pending'), ('close_approval', '=', 'pending')]),
            'recent_sheets': [self._sheet_row(s) for s in recent],
        }

    # ------------------------------------------------------------------
    # Stock sheets
    # ------------------------------------------------------------------
    def _sheet_row(self, s):
        return {'id': s.id, 'name': s.name, 'config': s.config_id.name, 'session': s.session_id.name or '',
                'state': s.state, 'opened': self._local(s, s.open_date), 'closed': self._local(s, s.close_date),
                'by_open': s.open_employee_id.name or '', 'by_close': s.close_employee_id.name or '',
                'open_diffs': s.open_diff_count, 'close_diffs': s.close_diff_count,
                'sales': round(s.amount_total, 2), 'variance': round(s.close_diff_value, 2), 'outside': s.opened_outside,
                'open_approval': s.open_approval, 'close_approval': s.close_approval,
                'open_approved_by': s.open_approved_by or '', 'close_approved_by': s.close_approved_by or '',
                'open_reason': s.open_reason or '', 'close_reason': s.close_reason or ''}

    @http.route('/utange/mgr/sheets', type='json', auth='user', methods=['POST'], csrf=False)
    def sheets(self, only_diffs=False, **kw):
        bad = self._check()
        if bad:
            return bad
        domain = ['|', '|', ('close_diff_count', '>', 0), ('open_approval', '=', 'pending'),
                  ('close_approval', '=', 'pending')] if only_diffs else []
        recs = request.env['utange.stock.sheet'].sudo().search(domain, order='open_date desc', limit=60)
        return {'ok': True, 'sheets': [self._sheet_row(s) for s in recs]}

    @http.route('/utange/mgr/sheet', type='json', auth='user', methods=['POST'], csrf=False)
    def sheet(self, sheet_id=None, **kw):
        bad = self._check()
        if bad:
            return bad
        s = request.env['utange.stock.sheet'].sudo().browse(int(sheet_id or 0)).exists()
        if not s:
            return {'ok': False, 'error': 'Stock sheet not found.'}
        if s.state == 'open':
            s._refresh_movements()  # live: sales and transfers so far
        now_qty = {l.product_id.id: l.product_id.with_context(location=(l.location_id or s.location_id).id).qty_available
                   for l in s.line_ids}
        data = self._sheet_row(s)
        data['location'] = ' · '.join(sorted(set(s.line_ids.mapped('point')))) or s.location_id.display_name
        data['lines'] = [{
            'name': l.product_id.display_name, 'uom': l.uom_id.name or '', 'price': l.price, 'point': l.point or '',
            'system_open': l.system_open, 'opening': l.counted_open, 'open_diff': l.open_diff,
            'received': l.received, 'sent_out': l.sent_out, 'sold': l.sold, 'amount': l.amount,
            'expected': l.expected_close, 'closing': l.counted_close if l.closed else None,
            'diff': l.close_diff if l.closed else None, 'on_hand': now_qty.get(l.product_id.id, 0.0),
        } for l in s.line_ids]
        return {'ok': True, 'sheet': data}

    @http.route('/utange/mgr/sheet_action', type='json', auth='user', methods=['POST'], csrf=False)
    def sheet_action(self, sheet_id=None, phase=None, action=None, **kw):
        """Approve / reject the opening or closing count differences."""
        bad = self._check()
        if bad:
            return bad
        if not request.env.user._utange_can_approve():
            return {'ok': False, 'error': 'You are not allowed to approve. Ask the admin to tick "Utange: can approve" on your user.'}
        s = request.env['utange.stock.sheet'].sudo().browse(int(sheet_id or 0)).exists()
        if not s or phase not in ('open', 'close') or action not in ('approve', 'reject'):
            return {'ok': False, 'error': 'Nothing to do.'}
        if s['%s_approval' % phase] != 'pending':
            return {'ok': False, 'error': 'These differences are not waiting for approval.'}
        try:
            if action == 'approve':
                s._approve(phase, request.env.user.name)
            else:
                s._reject(phase, request.env.user.name)
        except Exception as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        return {'ok': True, 'message': '%s differences %s.' % ('Opening' if phase == 'open' else 'Closing',
                                                               'approved: stock corrected' if action == 'approve' else 'rejected')}

    # ------------------------------------------------------------------
    # Requisitions
    # ------------------------------------------------------------------
    def _req(self, r, detail=False):
        data = {'id': r.id, 'name': r.name, 'date': self._local(r, r.date), 'state': r.state,
                'state_label': dict(r._fields['state'].selection).get(r.state, r.state),
                'by': r.employee_id.name or '', 'config': r.config_id.name, 'from': r.location_src_id.display_name,
                'point': r.point, 'point_label': dict(r._fields['point'].selection).get(r.point, ''),
                'to': r.location_dest_id.display_name, 'items': len(r.line_ids), 'note': (r.note or '').split('\n[')[0],
                'manager_note': r.manager_note or '', 'transfer': r.picking_id.name or '',
                'approved_by': r.approved_by_id.name or ''}
        if detail:
            prods = r.line_ids.product_id
            bar_now = {p.id: p.qty_available for p in prods.with_context(location=r.location_dest_id.id)}
            store_now = {p.id: p.qty_available for p in prods.with_context(location=r.location_src_id.id)}
            # The bar's current shift: opening count and sold so far, to judge the request.
            session = request.env['pos.session'].sudo().search(
                [('config_id', '=', r.config_id.id), ('state', 'in', ('opened', 'closing_control'))], limit=1)
            sheet = request.env['utange.stock.sheet'].sudo().search([('session_id', '=', session.id)], limit=1) \
                if session else request.env['utange.stock.sheet']
            if sheet:
                sheet._refresh_movements()
            by_prod = {l.product_id.id: l for l in sheet.line_ids} if sheet else {}
            week_start = fields.Datetime.now() - timedelta(days=7)
            sold_week = {}
            for pl in request.env['pos.order.line'].sudo().search([
                    ('product_id', 'in', prods.ids), ('order_id.config_id', '=', r.config_id.id),
                    ('order_id.state', 'in', ('paid', 'done', 'invoiced')), ('order_id.date_order', '>=', week_start)]):
                sold_week[pl.product_id.id] = sold_week.get(pl.product_id.id, 0.0) + pl.qty
            data['shift'] = {'session': session.name, 'sheet': sheet.name if sheet else ''} if session else None
            data['lines'] = []
            for l in r.line_ids:
                sl = by_prod.get(l.product_id.id)
                data['lines'].append({
                    'name': l.product_id.display_name, 'uom': l.uom_id.name or '', 'qty': l.qty, 'issued': l.qty_issued,
                    'note': l.note or '', 'bar_when_asked': l.bar_qty, 'store_when_asked': l.store_qty,
                    'bar_now': bar_now.get(l.product_id.id, 0.0), 'store_now': store_now.get(l.product_id.id, 0.0),
                    'shift_opening': sl.counted_open if sl else None, 'shift_sold': sl.sold if sl else None,
                    'shift_expected': sl.expected_close if sl else None,
                    'sold_7_days': sold_week.get(l.product_id.id, 0.0),
                })
        return data

    @http.route('/utange/mgr/requisitions', type='json', auth='user', methods=['POST'], csrf=False)
    def requisitions(self, state=None, **kw):
        bad = self._check()
        if bad:
            return bad
        domain = [('state', '=', state)] if state else []
        recs = request.env['utange.requisition'].sudo().search(domain, order='id desc', limit=60)
        return {'ok': True, 'requisitions': [self._req(r) for r in recs]}

    @http.route('/utange/mgr/requisition', type='json', auth='user', methods=['POST'], csrf=False)
    def requisition(self, requisition_id=None, **kw):
        bad = self._check()
        if bad:
            return bad
        r = request.env['utange.requisition'].sudo().browse(int(requisition_id or 0)).exists()
        if not r:
            return {'ok': False, 'error': 'Requisition not found.'}
        return {'ok': True, 'requisition': self._req(r, detail=True)}

    @http.route('/utange/mgr/requisition_action', type='json', auth='user', methods=['POST'], csrf=False)
    def requisition_action(self, requisition_id=None, action=None, note=None, qtys=None, **kw):
        """action: approve | reject. qtys: optional {line index: approved qty} to change quantities before approving."""
        bad = self._check()
        if bad:
            return bad
        r = request.env['utange.requisition'].sudo().browse(int(requisition_id or 0)).exists()
        if not r:
            return {'ok': False, 'error': 'Requisition not found.'}
        try:
            if note:
                r.manager_note = str(note)[:500]
            if action == 'approve':
                if qtys:
                    lines = r.line_ids
                    for k, v in dict(qtys).items():
                        i = int(k)
                        if 0 <= i < len(lines):
                            lines[i].qty = max(0.0, float(v or 0))
                r.action_approve()
                if r.state == 'done':
                    msg = '%s approved: stock moved %s → %s (%s).' % (r.name, r.location_src_id.display_name,
                                                                  r.location_dest_id.display_name, r.picking_id.name or '')
                else:
                    msg = '%s approved. Transfer %s is ready for the store.' % (r.name, r.picking_id.name or '')
            elif action == 'reject':
                r.action_reject()
                msg = '%s rejected.' % r.name
            else:
                return {'ok': False, 'error': 'Unknown action.'}
        except UserError as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        return {'ok': True, 'message': msg, 'requisition': self._req(r, detail=True)}

    # ------------------------------------------------------------------
    # Items: edit name, price, available in POS, category, bar / kitchen
    # ------------------------------------------------------------------
    def _cfg(self):
        return request.env['pos.config'].sudo().search([('active', '=', True)], order='id', limit=1)

    @http.route('/utange/mgr/meta', type='json', auth='user', methods=['POST'], csrf=False)
    def meta(self, **kw):
        bad = self._check()
        if bad:
            return bad
        env = request.env
        cfg = self._cfg()
        cats = env['pos.category'].sudo().search([], order='sequence, name')
        return {
            'ok': True,
            'categories': [{'id': c.id, 'name': c.display_name, 'point': c.utange_stock_point or '',
                            'effective': c._utange_point() or ''} for c in cats],
            'purchase': 'purchase.order' in env,
            'store': cfg._utange_store_location().display_name if cfg else '',
            'bar': cfg.utange_bar_location_id.display_name if cfg else '',
            'kitchen': cfg.utange_kitchen_location_id.display_name if cfg else '',
        }

    @http.route('/utange/mgr/category_point', type='json', auth='user', methods=['POST'], csrf=False)
    def category_point(self, category_id=None, point=None, **kw):
        bad = self._check()
        if bad:
            return bad
        c = request.env['pos.category'].sudo().browse(int(category_id or 0)).exists()
        if not c:
            return {'ok': False, 'error': 'Category not found.'}
        c.utange_stock_point = point if point in ('bar', 'kitchen') else False
        return {'ok': True, 'message': '%s: %s' % (c.display_name, dict(c._fields['utange_stock_point'].selection).get(c.utange_stock_point, 'not set'))}

    def _product(self, p, cfg):
        t = p.product_tmpl_id
        data = {'id': p.id, 'tmpl_id': t.id, 'name': t.name, 'price': t.list_price, 'cost': p.standard_price,
                'barcode': p.barcode or '', 'pos': bool(t.available_in_pos), 'sale_ok': bool(t.sale_ok),
                'storable': t.type == 'product', 'categ_ids': t.pos_categ_ids.ids,
                'categ': ', '.join(t.pos_categ_ids.mapped('name')), 'point': t.utange_stock_point or '',
                'effective_point': t._utange_point() or '', 'uom': p.uom_id.name or ''}
        if cfg and t.type == 'product':
            store = cfg._utange_store_location()
            here = cfg._utange_location_for(p)
            data['store_qty'] = p.with_context(location=store.id).qty_available if store else 0.0
            data['here_qty'] = p.with_context(location=here.id).qty_available if here else 0.0
            data['here'] = cfg._utange_point_label(t._utange_point())
        return data

    @http.route('/utange/mgr/products', type='json', auth='user', methods=['POST'], csrf=False)
    def products(self, q=None, only_pos=True, **kw):
        bad = self._check()
        if bad:
            return bad
        domain = [('sale_ok', '=', True)] if only_pos else []
        if only_pos:
            domain.append(('available_in_pos', '=', True))
        q = (q or '').strip()
        if q:
            domain += ['|', ('name', 'ilike', q), ('barcode', '=', q)]
        cfg = self._cfg()
        prods = request.env['product.product'].sudo().search(domain, order='name', limit=200)
        return {'ok': True, 'products': [self._product(p, cfg) for p in prods]}

    @http.route('/utange/mgr/product_save', type='json', auth='user', methods=['POST'], csrf=False)
    def product_save(self, product_id=None, name=None, price=None, pos=None, categ_ids=None, point=None,
                     storable=None, barcode=None, cost=None, **kw):
        bad = self._check()
        if bad:
            return bad
        env = request.env
        vals = {}
        if name is not None:
            if not str(name).strip():
                return {'ok': False, 'error': 'Enter the item name.'}
            vals['name'] = str(name).strip()[:120]
        if price is not None:
            vals['list_price'] = max(0.0, float(price or 0))
        if pos is not None:
            vals['available_in_pos'] = bool(pos)
            if pos:
                vals['sale_ok'] = True
        if categ_ids is not None:
            vals['pos_categ_ids'] = [(6, 0, [int(x) for x in categ_ids])]
        if point is not None:
            vals['utange_stock_point'] = point if point in ('bar', 'kitchen', 'main') else False
        if barcode is not None:
            vals['barcode'] = str(barcode).strip() or False
        Tmpl = env['product.template']
        try:
            p = env['product.product'].browse(int(product_id or 0)).exists()
            if p:
                if storable is not None and (p.type == 'product') != bool(storable):
                    vals['detailed_type'] = 'product' if storable else 'consu'
                p.product_tmpl_id.write(vals)
            else:
                if 'name' not in vals:
                    return {'ok': False, 'error': 'Enter the item name.'}
                vals.setdefault('available_in_pos', True)
                vals.setdefault('sale_ok', True)
                vals['detailed_type'] = 'product' if storable is None or storable else 'consu'
                p = Tmpl.create(vals).product_variant_id
            if cost is not None:
                p.standard_price = max(0.0, float(cost or 0))
        except Exception as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        return {'ok': True, 'message': '%s saved.' % p.display_name, 'product': self._product(p, self._cfg())}

    # ------------------------------------------------------------------
    # Purchases: buy and receive into the main store
    # ------------------------------------------------------------------
    @http.route('/utange/mgr/vendors', type='json', auth='user', methods=['POST'], csrf=False)
    def vendors(self, q=None, **kw):
        bad = self._check()
        if bad:
            return bad
        Partner = request.env['res.partner'].sudo()
        q = (q or '').strip()
        domain = [('is_company', '=', True)] if not q else ['|', ('name', 'ilike', q), ('phone', 'ilike', q)]
        if 'supplier_rank' in Partner._fields and not q:
            domain = [('supplier_rank', '>', 0)]
        found = Partner.search(domain, order='name', limit=30)
        return {'ok': True, 'vendors': [{'id': p.id, 'name': p.display_name, 'phone': p.phone or p.mobile or ''} for p in found]}

    def _receive(self, picking, store, qtys=None):
        picking = picking.sudo()
        if store and picking.location_dest_id != store:
            picking.location_dest_id = store
            picking.move_ids.write({'location_dest_id': store.id})
        for m in picking.move_ids:
            m.quantity = m.product_uom_qty
            m.picked = True
        picking.with_context(skip_backorder=True, picking_ids_not_to_backorder=picking.ids,
                             skip_sms=True, skip_immediate=True).button_validate()

    @http.route('/utange/mgr/purchase_create', type='json', auth='user', methods=['POST'], csrf=False)
    def purchase_create(self, vendor_id=None, vendor_name=None, lines=None, receive=True, ref=None, **kw):
        """lines: [{product_id, qty, price}]. With the Purchase app: a confirmed purchase order; else a stock receipt.
        receive=True: the goods are received into the main store now."""
        bad = self._check()
        if bad:
            return bad
        env = request.env
        cfg = self._cfg()
        store = cfg._utange_store_location() if cfg else env['stock.location']
        Partner = env['res.partner'].sudo()
        vendor = Partner.browse(int(vendor_id or 0)).exists()
        if not vendor and (vendor_name or '').strip():
            vendor = Partner.create({'name': vendor_name.strip()[:80], 'is_company': True})
        if not vendor:
            return {'ok': False, 'error': 'Choose the supplier.'}
        Product = env['product.product'].sudo()
        items = []
        for l in (lines or [])[:100]:
            p = Product.browse(int(l.get('product_id') or 0)).exists()
            qty = float(l.get('qty') or 0)
            if p and qty > 0:
                items.append((p, qty, float(l.get('price') or p.standard_price or 0)))
        if not items:
            return {'ok': False, 'error': 'Add at least one item with a quantity.'}
        try:
            if 'purchase.order' in env:
                wh = store.warehouse_id or (cfg.picking_type_id.warehouse_id if cfg else False)
                ptype = wh.in_type_id if wh else False
                vals = {'partner_id': vendor.id, 'partner_ref': (ref or '')[:60] or False,
                        'order_line': [(0, 0, {'product_id': p.id, 'product_qty': q, 'price_unit': pr, 'name': p.display_name,
                                               'product_uom': p.uom_po_id.id or p.uom_id.id, 'date_planned': fields.Datetime.now()})
                                       for p, q, pr in items]}
                if ptype:
                    vals['picking_type_id'] = ptype.id
                po = env['purchase.order'].create(vals)
                po.button_confirm()
                if receive:
                    for picking in po.picking_ids.filtered(lambda x: x.state not in ('done', 'cancel')):
                        self._receive(picking, store)
                msg = 'Purchase %s confirmed%s.' % (po.name, ' and received into %s' % store.display_name if receive else '')
                return {'ok': True, 'message': msg, 'ref': po.name, 'total': po.amount_total}
            # No Purchase app: a receipt from the supplier straight into the main store
            wh = store.warehouse_id or (cfg.picking_type_id.warehouse_id if cfg else False)
            ptype = wh.in_type_id if wh else env['stock.picking.type'].search([('code', '=', 'incoming')], limit=1)
            src = vendor.property_stock_supplier or env.ref('stock.stock_location_suppliers')
            picking = env['stock.picking'].sudo().create({
                'picking_type_id': ptype.id, 'partner_id': vendor.id, 'origin': (ref or 'Manager app')[:60],
                'location_id': src.id, 'location_dest_id': store.id,
                'move_ids': [(0, 0, {'name': p.display_name, 'product_id': p.id, 'product_uom_qty': q, 'product_uom': p.uom_id.id,
                                     'price_unit': pr, 'location_id': src.id, 'location_dest_id': store.id}) for p, q, pr in items],
            })
            picking.action_confirm()
            if receive:
                self._receive(picking, store)
            return {'ok': True, 'message': 'Receipt %s%s.' % (picking.name, ' done into %s' % store.display_name if receive else ' created'),
                    'ref': picking.name, 'total': sum(q * pr for _p, q, pr in items)}
        except Exception as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}

    @http.route('/utange/mgr/purchases', type='json', auth='user', methods=['POST'], csrf=False)
    def purchases(self, **kw):
        bad = self._check()
        if bad:
            return bad
        env = request.env
        out = []
        if 'purchase.order' in env:
            for po in env['purchase.order'].sudo().search([], order='id desc', limit=40):
                out.append({'ref': po.name, 'vendor': po.partner_id.name, 'date': self._local(po, po.date_order),
                            'total': po.amount_total, 'state': dict(po._fields['state'].selection).get(po.state, po.state),
                            'received': all(p.state == 'done' for p in po.picking_ids) if po.picking_ids else False,
                            'items': len(po.order_line)})
        else:
            for p in env['stock.picking'].sudo().search([('picking_type_code', '=', 'incoming')], order='id desc', limit=40):
                out.append({'ref': p.name, 'vendor': p.partner_id.name or '', 'date': self._local(p, p.scheduled_date),
                            'total': sum(m.price_unit * m.product_uom_qty for m in p.move_ids),
                            'state': dict(p._fields['state'].selection).get(p.state, p.state), 'received': p.state == 'done',
                            'items': len(p.move_ids)})
        return {'ok': True, 'purchase': 'purchase.order' in env, 'purchases': out}
