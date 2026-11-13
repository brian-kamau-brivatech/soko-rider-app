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
        if not (u.has_group('point_of_sale.group_pos_manager') or u.has_group('stock.group_stock_manager')):
            return {'ok': False, 'error': 'Only POS or Inventory managers can use the manager app.', 'denied': True}
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
                'approve': u.has_group('point_of_sale.group_pos_manager') or u.has_group('stock.group_stock_manager')}

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
                'sales': round(s.amount_total, 2), 'variance': round(s.close_diff_value, 2), 'outside': s.opened_outside}

    @http.route('/utange/mgr/sheets', type='json', auth='user', methods=['POST'], csrf=False)
    def sheets(self, only_diffs=False, **kw):
        bad = self._check()
        if bad:
            return bad
        domain = [('close_diff_count', '>', 0)] if only_diffs else []
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
        bar = s.location_id
        now_qty = {p.id: p.qty_available for p in s.line_ids.product_id.with_context(location=bar.id)}
        data = self._sheet_row(s)
        data['location'] = bar.display_name
        data['lines'] = [{
            'name': l.product_id.display_name, 'uom': l.uom_id.name or '', 'price': l.price,
            'system_open': l.system_open, 'opening': l.counted_open, 'open_diff': l.open_diff,
            'received': l.received, 'sent_out': l.sent_out, 'sold': l.sold, 'amount': l.amount,
            'expected': l.expected_close, 'closing': l.counted_close if l.closed else None,
            'diff': l.close_diff if l.closed else None, 'on_hand': now_qty.get(l.product_id.id, 0.0),
        } for l in s.line_ids]
        return {'ok': True, 'sheet': data}

    # ------------------------------------------------------------------
    # Requisitions
    # ------------------------------------------------------------------
    def _req(self, r, detail=False):
        data = {'id': r.id, 'name': r.name, 'date': self._local(r, r.date), 'state': r.state,
                'state_label': dict(r._fields['state'].selection).get(r.state, r.state),
                'by': r.employee_id.name or '', 'config': r.config_id.name, 'from': r.location_src_id.display_name,
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
