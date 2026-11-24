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
                'approve': u._utange_can_approve(),
                'perms': {p: u._utange_allowed(p) for p in ('sell', 'charge', 'open', 'close', 'requisition', 'purchase', 'items')}}

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
        denied = request.env.user._utange_denied('items')
        if denied:
            return {'ok': False, 'error': denied}
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
        denied = request.env.user._utange_denied('items')
        if denied:
            return {'ok': False, 'error': denied}
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
        denied = request.env.user._utange_denied('purchase')
        if denied:
            return {'ok': False, 'error': denied}
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

    # ------------------------------------------------------------------
    # Reports: sales, stock per day, employees bills
    # ------------------------------------------------------------------
    def _config(self, config_id=None):
        Config = request.env['pos.config'].sudo()
        cfg = Config.browse(int(config_id)).exists() if str(config_id or '').isdigit() and int(config_id) else Config
        return cfg if cfg and cfg.active else self._cfg()

    def _dates(self, date_from=None, date_to=None):
        today = fields.Date.context_today(request.env.user)
        try:
            first = fields.Date.to_date(date_from) if date_from else today
            last = fields.Date.to_date(date_to) if date_to else first
        except Exception:
            first = last = today
        if last < first:
            first, last = last, first
        if (last - first).days > 92:
            first = last - timedelta(days=92)
        start = datetime.combine(first, time.min) - timedelta(hours=3)  # EAT midnight in UTC
        end = datetime.combine(last, time.min) - timedelta(hours=3) + timedelta(days=1)
        return first, last, start, end

    @http.route('/utange/mgr/configs', type='json', auth='user', methods=['POST'], csrf=False)
    def configs(self, **kw):
        bad = self._check()
        if bad:
            return bad
        cfgs = request.env['pos.config'].sudo().search([('active', '=', True)], order='name')
        return {'ok': True, 'configs': [{'id': c.id, 'name': c.name} for c in cfgs]}

    @http.route('/utange/mgr/sales_report', type='json', auth='user', methods=['POST'], csrf=False)
    def sales_report(self, config_id=None, date_from=None, date_to=None, **kw):
        bad = self._check()
        if bad:
            return bad
        first, last, start, end = self._dates(date_from, date_to)
        domain = [('state', 'in', ('paid', 'done', 'invoiced')), ('date_order', '>=', start), ('date_order', '<', end)]
        if str(config_id or '').isdigit() and int(config_id):
            domain.append(('config_id', '=', int(config_id)))
        Order = request.env['pos.order'].sudo()
        orders = Order.search(domain, order='date_order desc')
        by_method, products, by_cashier, by_categ = {}, {}, {}, {}
        for p in orders.payment_ids:
            by_method[p.payment_method_id.name] = by_method.get(p.payment_method_id.name, 0) + p.amount
        for l in orders.lines:
            row = products.setdefault(l.product_id.id, {'name': l.product_id.display_name, 'qty': 0.0, 'total': 0.0})
            row['qty'] += l.qty
            row['total'] += l.price_subtotal_incl
            cat = l.product_id.pos_categ_ids[:1].name or 'Other'
            by_categ[cat] = by_categ.get(cat, 0.0) + l.price_subtotal_incl
        for o in orders:
            name = (o.employee_id.name if 'employee_id' in o._fields and o.employee_id else o.user_id.name) or '?'
            row = by_cashier.setdefault(name, {'name': name, 'count': 0, 'total': 0.0})
            row['count'] += 1
            row['total'] += o.amount_total
        days = []
        d = first
        while d <= last:
            ds = datetime.combine(d, time.min) - timedelta(hours=3)
            day_orders = orders.filtered(lambda o, ds=ds: ds <= o.date_order < ds + timedelta(days=1))
            days.append({'day': fields.Date.to_string(d), 'total': round(sum(day_orders.mapped('amount_total')), 2),
                         'count': len(day_orders)})
            d += timedelta(days=1)
        staff = orders.filtered('utange_staff_id')
        open_bills = Order.search([('state', '=', 'draft'), ('session_id.state', '!=', 'closed')] +
                                  ([('config_id', '=', int(config_id))] if str(config_id or '').isdigit() and int(config_id) else []))

        def rnd(rows, key='total'):
            return sorted(({k: (round(v, 2) if isinstance(v, float) else v) for k, v in r.items()} for r in rows),
                          key=lambda x: -x[key])
        return {
            'ok': True, 'from': fields.Date.to_string(first), 'to': fields.Date.to_string(last),
            'count': len(orders), 'total': round(sum(orders.mapped('amount_total')), 2),
            'tax': round(sum(orders.mapped('amount_tax')), 2),
            'staff_bills': round(sum(staff.mapped('amount_total')), 2), 'staff_bill_count': len(staff),
            'open_bills': round(sum(open_bills.mapped('amount_total')), 2), 'open_bill_count': len(open_bills),
            'by_method': [{'name': k, 'total': round(v, 2)} for k, v in sorted(by_method.items(), key=lambda x: -x[1])],
            'by_cashier': rnd(by_cashier.values()),
            'by_category': [{'name': k, 'total': round(v, 2)} for k, v in sorted(by_categ.items(), key=lambda x: -x[1])],
            'products': rnd(products.values())[:60],
            'days': list(reversed(days)) if len(days) > 1 else [],
        }

    @http.route('/utange/mgr/stock_report', type='json', auth='user', methods=['POST'], csrf=False)
    def stock_report(self, config_id=None, day=None, **kw):
        """One day: for every item the opening (first shift's opening count), what came in and went out, what was
        sold, and the closing (last shift's closing count) - across all the shifts that opened that day."""
        bad = self._check()
        if bad:
            return bad
        cfg = self._config(config_id)
        if not cfg:
            return {'ok': False, 'error': 'No Point of Sale.'}
        first, _last, start, end = self._dates(day, day)
        Sheet = request.env['utange.stock.sheet'].sudo()
        sheets = Sheet.search([('config_id', '=', cfg.id), ('state', '!=', 'draft'), ('open_date', '>=', start),
                               ('open_date', '<', end)], order='open_date asc, id asc')
        sheets.filtered(lambda s: s.state == 'open')._refresh_movements()
        items = {}
        for s in sheets:
            for l in s.line_ids:
                it = items.get(l.product_id.id)
                if it is None:
                    it = items[l.product_id.id] = {
                        'name': l.product_id.display_name, 'point': l.point or '', 'uom': l.uom_id.name or '',
                        'price': l.price, 'system_open': l.system_open, 'opening': l.counted_open, 'open_diff': l.open_diff,
                        'received': 0.0, 'sent_out': 0.0, 'sold': 0.0, 'amount': 0.0, 'closing': None, 'close_diff': 0.0,
                        'expected': 0.0}
                it['received'] += l.received
                it['sent_out'] += l.sent_out
                it['sold'] += l.sold
                it['amount'] += l.amount
                it['expected'] = l.expected_close
                if l.closed:
                    it['closing'] = l.counted_close
                    it['close_diff'] += l.close_diff
                else:
                    it['closing'] = None  # the last shift of the day is still open
        rows = sorted(items.values(), key=lambda r: ({'Bar': 0, 'Kitchen': 1}.get(r['point'], 2), r['name']))
        for r in rows:
            for k in ('received', 'sent_out', 'sold', 'amount', 'close_diff', 'expected'):
                r[k] = round(r[k], 3)
        return {
            'ok': True, 'config': cfg.name, 'day': fields.Date.to_string(first),
            'shifts': [self._sheet_row(s) for s in sheets],
            'items': rows,
            'sales': round(sum(r['amount'] for r in rows), 2),
            'variance': round(sum(r['close_diff'] * r['price'] for r in rows), 2),
            'open_variance': round(sum(r['open_diff'] * r['price'] for r in rows), 2),
        }

    def _staff_bill(self, o):
        return {'id': o.id, 'name': o.name, 'date': self._local(o, o.date_order), 'amount': round(o.amount_total, 2),
                'employee': o.utange_staff_id.name or '', 'employee_id': o.utange_staff_id.id,
                'by': (o.employee_id.name if 'employee_id' in o._fields and o.employee_id else o.user_id.name) or '',
                'reason': o.utange_staff_reason or '', 'cleared': bool(o.utange_staff_cleared),
                'cleared_by': o.utange_staff_cleared_by or '', 'cleared_on': self._local(o, o.utange_staff_cleared_date),
                'items': ', '.join('%g %s' % (l.qty, l.product_id.display_name) for l in o.lines[:6])}

    @http.route('/utange/mgr/staff_bills', type='json', auth='user', methods=['POST'], csrf=False)
    def staff_bills(self, state='open', employee_id=None, **kw):
        """Employees bills: credit sales to staff, open (to be paid / deducted) or cleared."""
        bad = self._check()
        if bad:
            return bad
        domain = [('utange_staff_id', '!=', False), ('state', '!=', 'cancel')]
        if state == 'open':
            domain.append(('utange_staff_cleared', '=', False))
        elif state == 'cleared':
            domain.append(('utange_staff_cleared', '=', True))
        if str(employee_id or '').isdigit() and int(employee_id):
            domain.append(('utange_staff_id', '=', int(employee_id)))
        orders = request.env['pos.order'].sudo().search(domain, order='date_order desc', limit=400)
        people = {}
        for o in orders:
            p = people.setdefault(o.utange_staff_id.id, {'employee_id': o.utange_staff_id.id, 'name': o.utange_staff_id.name,
                                                         'open': 0.0, 'cleared': 0.0, 'count': 0})
            p['count'] += 1
            p['cleared' if o.utange_staff_cleared else 'open'] += o.amount_total
        return {'ok': True, 'people': sorted(({**p, 'open': round(p['open'], 2), 'cleared': round(p['cleared'], 2)}
                                              for p in people.values()), key=lambda p: -p['open']),
                'bills': [self._staff_bill(o) for o in orders],
                'total_open': round(sum(o.amount_total for o in orders if not o.utange_staff_cleared), 2)}

    @http.route('/utange/mgr/staff_bill_clear', type='json', auth='user', methods=['POST'], csrf=False)
    def staff_bill_clear(self, order_ids=None, employee_id=None, undo=False, **kw):
        bad = self._check()
        if bad:
            return bad
        Order = request.env['pos.order'].sudo()
        if order_ids:
            orders = Order.browse([int(x) for x in order_ids]).exists().filtered('utange_staff_id')
        elif str(employee_id or '').isdigit():
            orders = Order.search([('utange_staff_id', '=', int(employee_id)), ('utange_staff_cleared', '=', False),
                                   ('state', '!=', 'cancel')])
        else:
            orders = Order
        if not orders:
            return {'ok': False, 'error': 'Nothing to clear.'}
        u = request.env.user
        if not (u._utange_can_approve() or u.has_group('point_of_sale.group_pos_manager')):
            return {'ok': False, 'error': 'Only a manager can clear employees bills.'}
        if undo:
            orders.write({'utange_staff_cleared': False, 'utange_staff_cleared_by': False, 'utange_staff_cleared_date': False})
        else:
            orders.write({'utange_staff_cleared': True, 'utange_staff_cleared_by': u.name,
                          'utange_staff_cleared_date': fields.Datetime.now()})
        return {'ok': True, 'message': '%d bill(s) %s.' % (len(orders), 'opened again' if undo else 'cleared')}

    # ------------------------------------------------------------------
    # Staff rights: waiters (orders and bills only) and cashiers (take payment)
    # ------------------------------------------------------------------
    PRESETS = {
        'waiter': {'sell': True, 'charge': False, 'open': False, 'close': False, 'requisition': True,
                   'purchase': False, 'items': False},
        'cashier': {'sell': True, 'charge': True, 'open': True, 'close': True, 'requisition': True,
                    'purchase': False, 'items': False},
    }

    def _can_set_rights(self):
        u = request.env.user
        return u.has_group('base.group_system') or u.has_group('point_of_sale.group_pos_manager') or u._utange_can_approve()

    def _staff_row(self, e, cfg):
        from ..models.res_users import PERMS
        holder = e.user_id or e
        admin = bool(e.user_id and (e.user_id._is_superuser() or e.user_id.has_group('base.group_system')))
        perms = {p: holder._utange_allowed(p) for p, _l in PERMS}
        if admin or not holder.utange_restrict:
            role = 'full'
        elif perms == self.PRESETS['waiter']:
            role = 'waiter'
        elif perms == self.PRESETS['cashier']:
            role = 'cashier'
        else:
            role = 'custom'
        return {'id': e.id, 'name': e.name, 'job': e.job_title or '', 'login': e.user_id.login or '',
                'has_pin': bool(e.pin), 'admin': admin, 'restrict': bool(holder.utange_restrict) and not admin,
                'perms': perms, 'role': role,
                'pos_manager': bool(cfg and cfg._utange_is_manager(employee=e)),
                'approver': bool(e.utange_approver or (e.user_id and e.user_id.utange_approver))}

    @http.route('/utange/mgr/staff', type='json', auth='user', methods=['POST'], csrf=False)
    def staff(self, **kw):
        bad = self._check()
        if bad:
            return bad
        from ..models.res_users import PERMS
        cfg = self._cfg()
        emps = request.env['hr.employee'].sudo().search([], order='name', limit=300)
        return {'ok': True, 'can_edit': self._can_set_rights(),
                'perm_labels': [{'key': p, 'label': l} for p, l in PERMS],
                'staff': [self._staff_row(e, cfg) for e in emps]}

    @http.route('/utange/mgr/staff_set', type='json', auth='user', methods=['POST'], csrf=False)
    def staff_set(self, employee_id=None, role=None, perms=None, **kw):
        """role: waiter | cashier | full, or custom perms {perm: bool}. Staff with an Odoo login: set on the login."""
        bad = self._check()
        if bad:
            return bad
        if not self._can_set_rights():
            return {'ok': False, 'error': 'Only POS managers can change rights.'}
        from ..models.res_users import PERMS
        e = request.env['hr.employee'].sudo().browse(int(employee_id or 0)).exists()
        if not e:
            return {'ok': False, 'error': 'Employee not found.'}
        if e.user_id and (e.user_id._is_superuser() or e.user_id.has_group('base.group_system')):
            return {'ok': False, 'error': '%s is an administrator: always allowed everything.' % e.name}
        holder = e.user_id.sudo() if e.user_id else e
        if role == 'full':
            vals = {'utange_restrict': False}
        else:
            chosen = dict(self.PRESETS.get(role) or {})
            if not chosen:
                chosen = {p: bool((perms or {}).get(p)) for p, _l in PERMS}
            vals = {'utange_restrict': True, **{'utange_perm_%s' % p: bool(chosen.get(p)) for p, _l in PERMS}}
        holder.write(vals)
        e.message_post(body='Utange rights changed by %s: %s.' % (request.env.user.name, role or 'custom'))
        return {'ok': True, 'message': '%s: %s.' % (e.name, {'waiter': 'waiter (orders and bills, no payment)',
                                                                'cashier': 'cashier (takes payment)',
                                                                'full': 'everything'}.get(role, 'rights saved')),
                'staff': self._staff_row(e, self._cfg())}

    # ------------------------------------------------------------------
    # Stock take (exact quantities) and transfers main store -> bar / kitchen
    # ------------------------------------------------------------------
    def _point_location(self, cfg, point):
        if point == 'bar':
            return cfg.utange_bar_location_id
        if point == 'kitchen':
            return cfg.utange_kitchen_location_id
        if point == 'main':
            return cfg._utange_location()
        return cfg._utange_store_location()

    def _can_stock(self):
        u = request.env.user
        return u.has_group('stock.group_stock_manager') or u.has_group('point_of_sale.group_pos_manager') \
            or u._utange_can_approve()

    @http.route('/utange/mgr/stock_take_lines', type='json', auth='user', methods=['POST'], csrf=False)
    def stock_take_lines(self, config_id=None, point='store', q=None, **kw):
        bad = self._check()
        if bad:
            return bad
        cfg = self._config(config_id)
        loc = self._point_location(cfg, point) if cfg else None
        if not loc:
            return {'ok': False, 'error': 'This location is not set on the Point of Sale (Handheld settings).'}
        products = cfg._utange_products(storable=True)
        if point in ('bar', 'kitchen'):
            products = products.filtered(lambda p: p.product_tmpl_id._utange_point() == point)
        q = (q or '').strip().lower()
        if q:
            products = products.filtered(lambda p: q in p.display_name.lower())
        points = [{'point': 'store', 'label': 'Main store', 'location': cfg._utange_store_location().display_name}]
        for pt, label in (('bar', 'Bar'), ('kitchen', 'Kitchen')):
            l = self._point_location(cfg, pt)
            if l and l != cfg._utange_store_location():
                points.append({'point': pt, 'label': label, 'location': l.display_name})
        return {'ok': True, 'location': loc.display_name, 'points': points, 'config': cfg.name,
                'items': [{'product_id': p.id, 'name': p.display_name, 'uom': p.uom_id.name or '',
                           'categ': p.pos_categ_ids[:1].name or '',
                           'qty': p.with_context(location=loc.id).qty_available} for p in products]}

    @http.route('/utange/mgr/stock_take_apply', type='json', auth='user', methods=['POST'], csrf=False)
    def stock_take_apply(self, config_id=None, point='store', counts=None, note=None, **kw):
        """counts: [{product_id, qty}] = what is really there. Odoo's stock is set to it (inventory adjustment)."""
        bad = self._check()
        if bad:
            return bad
        if not self._can_stock():
            return {'ok': False, 'error': 'Only managers can do a stock take.'}
        cfg = self._config(config_id)
        loc = self._point_location(cfg, point) if cfg else None
        if not loc:
            return {'ok': False, 'error': 'This location is not set on the Point of Sale.'}
        env = request.env
        Move = env['stock.move'].sudo()
        Product = env['product.product'].sudo()
        done = []
        try:
            for c in (counts or [])[:1500]:
                p = Product.browse(int(c.get('product_id') or 0)).exists()
                if not p or p.type != 'product' or c.get('qty') in (None, ''):
                    continue
                diff = float(c['qty']) - p.with_context(location=loc.id).qty_available
                if abs(diff) < 0.0001:
                    continue
                inv = p.with_company(cfg.company_id).property_stock_inventory
                src, dst = (inv, loc) if diff > 0 else (loc, inv)
                m = Move.create({'name': 'Utange stock take (%s)' % (note or env.user.name)[:60], 'origin': 'Stock take',
                                 'product_id': p.id, 'product_uom': p.uom_id.id, 'product_uom_qty': abs(diff),
                                 'location_id': src.id, 'location_dest_id': dst.id, 'company_id': cfg.company_id.id,
                                 'is_inventory': True})
                m._action_confirm()
                m.quantity = abs(diff)
                m.picked = True
                m._action_done()
                done.append('%s %+g' % (p.display_name, diff))
        except Exception as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        return {'ok': True, 'changed': len(done),
                'message': ('Stock take saved: %d items corrected in %s.' % (len(done), loc.display_name)) if done
                else 'Stock take saved: everything matched.'}

    @http.route('/utange/mgr/transfer', type='json', auth='user', methods=['POST'], csrf=False)
    def transfer(self, config_id=None, to='bar', lines=None, **kw):
        """Moves stock from the main store to the bar or the kitchen now (lines: [{product_id, qty}])."""
        bad = self._check()
        if bad:
            return bad
        if not self._can_stock():
            return {'ok': False, 'error': 'Only managers can transfer stock.'}
        cfg = self._config(config_id)
        src = cfg._utange_store_location() if cfg else None
        dst = self._point_location(cfg, to) if cfg and to in ('bar', 'kitchen', 'main') else None
        if not src or not dst or src == dst:
            return {'ok': False, 'error': 'Set the main store and the %s locations on the Point of Sale first.' % to}
        env = request.env
        Product = env['product.product'].sudo()
        items = []
        for l in (lines or [])[:300]:
            p = Product.browse(int(l.get('product_id') or 0)).exists()
            q = float(l.get('qty') or 0)
            if p and q > 0:
                items.append((p, q))
        if not items:
            return {'ok': False, 'error': 'Add at least one item with a quantity.'}
        wh = src.warehouse_id or cfg.picking_type_id.warehouse_id
        ptype = wh.int_type_id if wh else env['stock.picking.type'].sudo().search(
            [('code', '=', 'internal'), ('company_id', 'in', (cfg.company_id.id, False))], limit=1)
        if not ptype:
            return {'ok': False, 'error': 'No internal transfer type: enable Storage Locations in Inventory settings.'}
        try:
            picking = env['stock.picking'].sudo().create({
                'picking_type_id': ptype.id, 'location_id': src.id, 'location_dest_id': dst.id,
                'origin': 'Manager app transfer (%s)' % env.user.name,
                'move_ids': [(0, 0, {'name': p.display_name, 'product_id': p.id, 'product_uom_qty': q,
                                     'product_uom': p.uom_id.id, 'location_id': src.id, 'location_dest_id': dst.id})
                             for p, q in items]})
            picking.action_confirm()
            short = []
            for m in picking.move_ids:
                have = m.product_id.with_context(location=src.id).qty_available
                give = max(0.0, min(m.product_uom_qty, have))
                if give < m.product_uom_qty:
                    short.append('%s (store has %g)' % (m.product_id.display_name, max(have, 0)))
                m.quantity = give
                m.picked = True
            if not any(m.quantity > 0 for m in picking.move_ids):
                request.env.cr.rollback()
                return {'ok': False, 'error': 'The main store has none of these items. Do a stock take of the main store first.'}
            picking.move_ids.filtered(lambda m: m.quantity <= 0)._action_cancel()
            picking.with_context(skip_backorder=True, picking_ids_not_to_backorder=picking.ids,
                                 skip_sms=True, skip_immediate=True).button_validate()
        except Exception as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        return {'ok': True, 'message': '%s done: %s → %s.%s' % (picking.name, src.display_name, dst.display_name,
                                                                (' Short: ' + '; '.join(short)) if short else '')}
