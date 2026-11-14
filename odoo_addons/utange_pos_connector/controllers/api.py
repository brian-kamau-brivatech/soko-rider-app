# -*- coding: utf-8 -*-
"""JSON API for the Utange POS handheld app.

Security: the device is set up once with the device PIN (System Parameter
utange_pos.device_pin, set by BRV). Cashiers then sign in with their POS
employee PIN (Point of Sale > Log in with employees), and every money or stock
action carries a signed cashier token.

Sales are saved with Odoo's own pos.order.create_from_ui, exactly like the POS
screen, so stock, accounting, session totals and reports are the same.
"""
import time as _time
import uuid
from datetime import datetime, time, timedelta

from odoo import fields, http
from odoo.exceptions import AccessError, UserError, ValidationError
from odoo.http import request
from odoo.tools import consteq
from odoo.tools.misc import hmac as _hmac

PARAM_PIN = 'utange_pos.device_pin'
PARAM_FAILS = 'utange_pos.device_fails'
PARAM_SEQ = 'utange_pos.seq_%s'
APP_LOGIN_NUMBER = 778  # keeps handheld receipt numbers apart from the POS screen's


def _f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def _err(e):
    return str(e.args[0] if getattr(e, 'args', None) else e)


class UtangePosApi(http.Controller):

    # ------------------------------------------------------------------
    # Device and POS
    # ------------------------------------------------------------------
    def _device_secret(self):
        P = request.env['ir.config_parameter'].sudo()
        s = P.get_param('utange_pos.device_secret')
        if not s:
            s = uuid.uuid4().hex
            P.set_param('utange_pos.device_secret', s)
        return s

    def _device_token(self):
        return 'D.' + _hmac(request.env(su=True), 'utange-pos-device', self._device_secret())

    def _ok(self, pin):
        pin = str(pin or '').strip()
        if pin.startswith('D.'):
            # A handheld registered with a POS manager's PIN (change utange_pos.device_secret to revoke all).
            return (True, '') if consteq(pin, self._device_token()) else (False, 'This handheld must be set up again.')
        P = request.env['ir.config_parameter'].sudo()
        expected = (P.get_param(PARAM_PIN) or '').strip()
        if not expected:
            return False, 'The handheld is not enabled yet: BRV must set the device PIN in Odoo (%s).' % PARAM_PIN
        fails = int(P.get_param(PARAM_FAILS) or 0)
        if fails >= 20:
            return False, 'Too many wrong device PINs. BRV must reset the device PIN in Odoo.'
        if not pin or not consteq(str(pin).strip(), expected):
            P.set_param(PARAM_FAILS, str(fails + 1))
            return False, 'Wrong device PIN.'
        if fails:
            P.set_param(PARAM_FAILS, '0')
        return True, ''

    def _config(self, config_id):
        Config = request.env['pos.config'].sudo()
        config = Config.browse(int(config_id or 0)).exists() if str(config_id or '').isdigit() else Config
        if config and not config.active:
            config = Config
        return config

    def _guard(self, pin, config_id, cashier=None, need_cashier=True):
        """(config, employee, role, error_response)."""
        ok, msg = self._ok(pin)
        if not ok:
            return None, None, None, {'ok': False, 'error': msg, 'device': True}
        config = self._config(config_id)
        if not config:
            return None, None, None, {'ok': False, 'error': 'This Point of Sale no longer exists. Choose it again in Settings.',
                                      'reconfigure': True}
        emp, role, err = self._cashier(config, cashier)
        if err and need_cashier:
            return config, None, None, {'ok': False, 'error': err, 'cashier_required': True}
        return config, emp, role, None

    def _line_values(self, product, qty, price):
        taxes = product.taxes_id.filtered(lambda t: t.company_id == request.env.company) or product.taxes_id
        res = taxes.compute_all(price, request.env.company.currency_id, qty, product=product)
        return taxes, res['total_excluded'], res['total_included']

    def _local(self, rec, dt):
        return fields.Datetime.to_string(fields.Datetime.context_timestamp(rec, dt)) if dt else ''

    # ------------------------------------------------------------------
    # Cashiers: POS employees (pos_hr), same people, roles and PINs
    # ------------------------------------------------------------------
    def _hr_on(self, config):
        return bool(config) and 'module_pos_hr' in config._fields and config.module_pos_hr and 'hr.employee' in request.env

    def _pos_user(self, config, session=None):
        if session and session.user_id:
            return session.user_id
        last = request.env['pos.session'].sudo().search([('config_id', '=', config.id), ('user_id', '!=', False)],
                                                         order='id desc', limit=1)
        return last.user_id or request.env.ref('base.user_admin')

    def _as_pos_user(self, config, session=None):
        return request.env(user=self._pos_user(config, session).id, su=True)

    def _live_session(self, config):
        return request.env['pos.session'].sudo().search(
            [('config_id', '=', config.id), ('state', '!=', 'closed'), ('rescue', '=', False)], order='id desc', limit=1)

    def _open_session(self, config):
        s = self._live_session(config)
        return s if s and s.state == 'opened' else None

    def _cashier_list(self, config):
        user = self._pos_user(config, self._live_session(config))
        emps = request.env['hr.employee'].sudo().search(config.sudo()._employee_domain(user.id), order='name')
        managers = config.group_pos_manager_id
        out = []
        for e in emps:
            manager = (e.user_id and managers and managers in e.user_id.groups_id) or e in config.advanced_employee_ids
            out.append((e, 'manager' if manager else 'cashier'))
        return out

    def _cashier_token(self, config, emp):
        msg = '%s:%s:%s' % (emp.id, emp.sudo().pin or '', config.id)
        return '%d.%s' % (emp.id, _hmac(request.env(su=True), 'utange-pos-cashier', msg))

    def _cashier(self, config, token):
        """(employee, role, error). With POS employee login off: (None, None, None)."""
        if not self._hr_on(config):
            return None, None, None
        token = str(token or '')
        if '.' not in token:
            return None, None, 'Sign in with your POS PIN first.'
        emp_id = token.split('.', 1)[0]
        for emp, role in self._cashier_list(config):
            if str(emp.id) == emp_id and consteq(token, self._cashier_token(config, emp)):
                return emp, role, None
        return None, None, 'Sign in with your POS PIN first.'

    def _can_close(self, emp, role, session):
        if not emp:
            return True
        return bool((role == 'manager' and emp.user_id) or (emp.user_id and session and emp.user_id == session.user_id))

    def _log_as(self, rec, emp, body):
        try:
            author = emp.work_contact_id.id if emp and emp.work_contact_id else False
            rec.sudo().message_post(body=body, author_id=author or None)
        except Exception:
            pass

    def _manager_pin_ok(self, pin):
        """True when pin is the employee PIN of a POS manager of any active POS."""
        pin = str(pin or '').strip()
        if len(pin) < 3:
            return False
        for config in request.env['pos.config'].sudo().search([('active', '=', True)]):
            if not self._hr_on(config):
                continue
            for emp, role in self._cashier_list(config):
                if role == 'manager' and emp.sudo().pin and consteq(pin, emp.sudo().pin):
                    return True
        return False

    @http.route('/utange/pos/configs', type='json', auth='public', methods=['POST'], csrf=False)
    def configs(self, pin=None, **kw):
        """Set-up: the BRV device PIN or a POS manager's employee PIN. Returns a device token to keep."""
        token = None
        ok, msg = self._ok(pin)
        if not ok and not str(pin or '').startswith('D.'):
            P = request.env['ir.config_parameter'].sudo()
            fails = int(P.get_param(PARAM_FAILS) or 0)
            if fails < 20 and self._manager_pin_ok(pin):
                ok, token = True, self._device_token()
                P.set_param(PARAM_FAILS, '0')
            elif str(pin or '').strip():
                msg = 'Wrong PIN. Use a POS manager\'s employee PIN (or the BRV device PIN).'
        if not ok:
            return {'ok': False, 'error': msg, 'device': True}
        if token is None:
            token = self._device_token()
        company = request.env.company
        configs = request.env['pos.config'].sudo().search([('active', '=', True)], order='name')
        return {'ok': True, 'token': token,
                'company': {'id': company.id, 'name': company.name},
                'configs': [{'id': c.id, 'name': c.name, 'cashiers_on': self._hr_on(c),
                             'open': bool(self._open_session(c))} for c in configs]}

    @http.route('/utange/pos/cashiers', type='json', auth='public', methods=['POST'], csrf=False)
    def cashiers(self, pin=None, config_id=None, **kw):
        config, _e, _r, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        if not self._hr_on(config):
            return {'ok': True, 'enabled': False, 'cashiers': []}
        return {'ok': True, 'enabled': True, 'cashiers': [
            {'id': e.id, 'name': e.name, 'role': role, 'has_pin': bool(e.sudo().pin), 'job': e.job_title or ''}
            for e, role in self._cashier_list(config)]}

    @http.route('/utange/pos/cashier_login', type='json', auth='public', methods=['POST'], csrf=False)
    def cashier_login(self, pin=None, config_id=None, employee_id=None, employee_pin=None, **kw):
        config, _e, _r, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        if not self._hr_on(config):
            return {'ok': True, 'enabled': False}
        match = [(e, r) for e, r in self._cashier_list(config) if e.id == int(employee_id or 0)]
        if not match:
            return {'ok': False, 'error': 'This person is not a cashier of %s.' % config.name}
        emp, role = match[0]
        P = request.env['ir.config_parameter'].sudo()
        key = 'utange_pos.cashier_fails_%d' % emp.id
        fails, until = (P.get_param(key) or '0|0').split('|')
        now = int(_time.time())
        if int(until) > now:
            return {'ok': False, 'error': 'Too many wrong PINs. Try again in %d min.' % ((int(until) - now) // 60 + 1)}
        real = emp.sudo().pin or ''
        if real and not consteq(str(employee_pin or '').strip(), real):
            fails = int(fails) + 1
            P.set_param(key, '0|%d' % (now + 300) if fails >= 5 else '%d|0' % fails)
            return {'ok': False, 'error': 'Wrong PIN.'}
        P.set_param(key, '0|0')
        return {'ok': True, 'enabled': True, 'token': self._cashier_token(config, emp),
                'cashier': {'id': emp.id, 'name': emp.name, 'role': role}}

    # ------------------------------------------------------------------
    # Products, payment methods, receipt details
    # ------------------------------------------------------------------
    @http.route('/utange/pos/setup', type='json', auth='public', methods=['POST'], csrf=False)
    def setup(self, pin=None, config_id=None, **kw):
        config, _e, _r, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        session = self._open_session(config)
        products = config._utange_products()
        on_hand = config._utange_available(products, session)
        cats, items = {}, []
        for p in products:
            for c in p.pos_categ_ids:
                cats[c.id] = {'id': c.id, 'name': c.name, 'sequence': c.sequence or 0}
            _t, _x, incl = self._line_values(p, 1, p.lst_price)
            items.append({
                'id': p.id, 'name': p.display_name, 'price': incl, 'uom': p.uom_id.name or '',
                'barcode': p.barcode or '', 'categ_ids': p.pos_categ_ids.ids,
                'qty': on_hand.get(p.id) if p.type == 'product' else None,
                'point': p.product_tmpl_id._utange_point() or '',
                'image': '/web/image/product.product/%d/image_128' % p.id,
            })
        company = request.env.company
        return {
            'ok': True,
            'config': {'id': config.id, 'name': config.name},
            'session': {'id': session.id, 'name': session.name, 'user': session.user_id.name} if session else None,
            'payment_methods': [{'id': m.id, 'name': m.name, 'cash': bool(m.is_cash_count),
                                 'mpesa': 'mpesa' in (m.name or '').lower().replace('-', '').replace(' ', ''),
                                 'account': self._pay_later(m)}
                                for m in config.payment_method_ids],
            'categories': sorted(cats.values(), key=lambda c: (c['sequence'], c['name'])),
            'products': items,
            'company': {'id': company.id, 'name': company.name, 'phone': company.phone or '', 'email': company.email or '',
                        'vat': company.vat or '', 'address': ', '.join(x for x in (company.street, company.city) if x)},
            'receipt_header': (config.receipt_header or '') if 'receipt_header' in config._fields else '',
            'receipt_footer': (config.receipt_footer or '') if 'receipt_footer' in config._fields else '',
            'block_zero': bool(config.utange_block_zero),
            'needs_open_count': bool(session and config.utange_require_sheet and not self._sheet_of(session)),
            **self._receipt_printer(config),
            'kitchen_printers': self._kitchen_printers(config),
            'points': [{'point': pt, 'label': label, 'location': loc.display_name} for pt, label, loc in config._utange_points()],
        }

    def _kitchen_printers(self, config):
        """Odoo order printers (Point of Sale > Preparation printers) with a network IP: kitchen / bar tickets."""
        out = []
        if not getattr(config, 'is_order_printer', False):
            return out
        for pr in config.printer_ids:
            via = 'direct'
            ip = ''
            if getattr(pr, 'printer_type', '') == 'escpos_printer':
                ip, via = (getattr(pr, 'escpos_printer_ip', '') or '').strip(), 'odoo'  # pos_escpos: Odoo sends it
            if not ip or ip == '0.0.0.0':
                ip = (getattr(pr, 'epson_printer_ip', '') or getattr(pr, 'proxy_ip', '') or '').strip()
                via = 'direct'
            if not ip or ip == '0.0.0.0':
                continue
            cats = request.env['pos.category'].sudo().search([('id', 'child_of', pr.product_categories_ids.ids)]).ids \
                if pr.product_categories_ids else []
            out.append({'id': pr.id, 'name': pr.name, 'ip': ip, 'via': via, 'categ_ids': cats})
        return out

    def _receipt_printer(self, config):
        """The bill printer set on the POS: pos_escpos (sent through Odoo) or an Epson IP."""
        ip = (getattr(config, 'escpos_printer_ip', '') or '').strip() if getattr(config, 'escpos_print', False) else ''
        if ip and ip != '0.0.0.0':
            return {'receipt_printer_ip': ip, 'receipt_printer_via': 'odoo'}
        ip = (getattr(config, 'epson_printer_ip', '') or '').strip()
        if ip and ip != '0.0.0.0':
            return {'receipt_printer_ip': ip, 'receipt_printer_via': 'direct'}
        return {'receipt_printer_ip': '', 'receipt_printer_via': ''}

    def _pay_later(self, m):
        return bool(getattr(m, 'split_transactions', False) or getattr(m, 'type', '') == 'pay_later')

    @http.route('/utange/pos/customers', type='json', auth='public', methods=['POST'], csrf=False)
    def customers(self, pin=None, config_id=None, q=None, **kw):
        """Customer search (for Customer Account / room charges)."""
        config, _e, _r, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        q = (q or '').strip()
        if len(q) < 2:
            return {'ok': True, 'customers': []}
        Partner = request.env['res.partner'].sudo()
        found = Partner.search(['|', '|', '|', ('name', 'ilike', q), ('phone', 'ilike', q), ('mobile', 'ilike', q),
                                ('ref', 'ilike', q), ('active', '=', True)], order='name', limit=25)
        return {'ok': True, 'customers': [{'id': p.id, 'name': p.display_name, 'phone': p.phone or p.mobile or ''}
                                          for p in found]}

    # ------------------------------------------------------------------
    # Sell
    # ------------------------------------------------------------------
    @http.route('/utange/pos/sell', type='json', auth='public', methods=['POST'], csrf=False)
    def sell(self, pin=None, config_id=None, cashier=None, lines=None, payments=None, customer_name=None, customer_id=None,
             uid=None, **kw):
        """lines: [{product_id, qty, price?}]; payments: [{method_id, amount, ref?}]"""
        config, emp, role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        env = request.env
        session = self._open_session(config)
        if not session:
            return {'ok': False, 'error': 'The shift is closed. Open it first (More > Shift).'}
        if config.utange_require_sheet and not self._sheet_of(session):
            return {'ok': False, 'error': 'This shift was opened in Odoo: confirm the opening stock count first.',
                    'count_required': True}
        Order = env['pos.order'].sudo()
        uid = str(uid or '').strip()[:64]
        if uid:
            done = Order.search([('access_token', '=', uid)], limit=1)
            if done:
                return {'ok': True, 'order': self._sale(done, detail=True)}
        if any(l.get('price') not in (None, '') for l in (lines or [])) and emp and role != 'manager' \
                and getattr(config, 'restrict_price_control', False):
            return {'ok': False, 'error': 'Only a POS manager can change prices (same as Odoo POS).'}
        allowed = set(config._utange_products().ids)
        Product = env['product.product'].sudo()
        ui_lines, total, tax_total = [], 0.0, 0.0
        for l in (lines or [])[:200]:
            p = Product.browse(int(l.get('product_id') or 0)).exists()
            qty = _f(l.get('qty'))
            if not p or p.id not in allowed or qty == 0:
                continue
            taxes, _e, _i = self._line_values(p, 1, p.lst_price)
            unit = p.lst_price
            if l.get('price') not in (None, ''):
                unit = _f(l['price']) / (_i / _e) if taxes and _e else _f(l['price'])
            taxes, excl, incl = self._line_values(p, qty, unit)
            total += incl
            tax_total += incl - excl
            ui_lines.append([0, 0, {
                'product_id': p.id, 'qty': qty, 'price_unit': unit, 'discount': 0,
                'price_subtotal': excl, 'price_subtotal_incl': incl,
                'tax_ids': [(6, 0, taxes.ids)], 'full_product_name': p.display_name, 'pack_lot_ids': [],
            }])
        if not ui_lines:
            return {'ok': False, 'error': 'Add at least one item.'}
        if config.utange_block_zero:
            wanted = {}
            for ln in ui_lines:
                wanted[ln[2]['product_id']] = wanted.get(ln[2]['product_id'], 0.0) + ln[2]['qty']
            prods = Product.browse(list(wanted)).filtered(lambda p: p.type == 'product')
            avail = config._utange_available(prods, session)
            short = []
            for p in prods:
                if wanted[p.id] > 0 and avail.get(p.id, 0.0) + 0.0001 < wanted[p.id]:
                    short.append('%s (%s has %g)' % (p.display_name, config._utange_point_label(p.product_tmpl_id._utange_point()),
                                                    max(avail.get(p.id, 0.0), 0)))
            if short:
                return {'ok': False, 'error': 'Not enough stock: %s. Make a requisition to the main store.' % ', '.join(short[:5]),
                        'no_stock': True}
        total = round(total, 2)
        methods = {m.id: m for m in config.payment_method_ids}
        ui_payments, paid, change = [], 0.0, 0.0
        now = fields.Datetime.to_string(fields.Datetime.now())
        for pay in (payments or []):
            m = methods.get(int(pay.get('method_id') or 0))
            amt = round(_f(pay.get('amount')), 2)
            if not m or amt <= 0:
                continue
            ui_payments.append([0, 0, {'name': now, 'payment_method_id': m.id, 'amount': amt,
                                       'transaction_id': str(pay.get('ref') or '').strip()[:60]}])
            paid += amt
        if round(paid, 2) + 0.001 < total:
            return {'ok': False, 'error': 'Payment is short: KSh %.0f of KSh %.0f.' % (paid, total)}
        if paid > total:
            change = round(paid - total, 2)
            if not [p for p in ui_payments if methods[p[2]['payment_method_id']].is_cash_count]:
                return {'ok': False, 'error': 'Only cash can be more than the total.'}
        partner = False
        name = (customer_name or '').strip()
        if customer_id:
            partner = env['res.partner'].sudo().browse(int(customer_id)).exists()
        if not partner and name:
            Partner = env['res.partner'].sudo()
            partner = Partner.search([('name', '=ilike', name)], limit=1) or Partner.create({'name': name[:80]})
        if not partner and any(self._pay_later(methods[p[2]['payment_method_id']]) for p in ui_payments):
            return {'ok': False, 'error': 'Choose the customer for a Customer Account sale.'}
        P = env['ir.config_parameter'].sudo()
        seq = int(P.get_param(PARAM_SEQ % session.id) or 0) + 1
        P.set_param(PARAM_SEQ % session.id, str(seq))
        ref = 'Order %05d-%03d-%04d' % (session.id, APP_LOGIN_NUMBER, seq)
        data = {
            'name': ref, 'uid': ref[6:], 'sequence_number': seq,
            'pos_session_id': session.id, 'user_id': session.user_id.id,
            'partner_id': partner.id if partner else False,
            'date_order': now, 'creation_date': now,
            'fiscal_position_id': config.default_fiscal_position_id.id or False,
            'pricelist_id': config.pricelist_id.id or False,
            'amount_total': total, 'amount_tax': round(tax_total, 2),
            'amount_paid': round(paid, 2), 'amount_return': change,
            'lines': ui_lines, 'statement_ids': ui_payments,
            'to_invoice': False, 'shipping_date': False, 'is_tipped': False, 'tip_amount': 0,
            'access_token': uid or str(uuid.uuid4()),
        }
        if emp:
            data['employee_id'] = emp.id
        try:
            res = Order.create_from_ui([{'data': data, 'to_invoice': False}], draft=False)
        except (UserError, ValidationError) as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        order = Order.browse(res[0]['id']) if res else Order.search([('pos_reference', '=', ref)], limit=1)
        if not order:
            return {'ok': False, 'error': 'Odoo did not save the sale.'}
        return {'ok': True, 'order': self._sale(order, detail=True)}

    def _sale(self, o, detail=False):
        data = {
            'id': o.id, 'name': o.name, 'ref': o.pos_reference or '',
            'date': self._local(o, o.date_order),
            'amount': o.amount_total, 'tax': o.amount_tax, 'paid': o.amount_paid, 'change': o.amount_return,
            'state': o.state, 'customer': o.partner_id.name or '',
            'cashier': (o.employee_id.name if 'employee_id' in o._fields and o.employee_id else o.user_id.name) or '',
            'session': o.session_id.name or '', 'config': o.config_id.name or '',
            'from_app': (o.pos_reference or '').split('-')[1:2] == ['%03d' % APP_LOGIN_NUMBER],
            'payments': [{'method': p.payment_method_id.name, 'amount': p.amount, 'ref': p.transaction_id or ''}
                         for p in o.payment_ids],
            'count': int(sum(o.lines.mapped('qty'))),
        }
        if detail:
            data['lines'] = [{'name': l.full_product_name or l.product_id.display_name, 'qty': l.qty,
                              'price': round(l.price_subtotal_incl / l.qty, 2) if l.qty else l.price_unit,
                              'total': l.price_subtotal_incl} for l in o.lines]
        return data

    @http.route('/utange/pos/sales', type='json', auth='public', methods=['POST'], csrf=False)
    def sales(self, pin=None, config_id=None, period=None, cashier=None, **kw):
        config, _emp, _role, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        Order = request.env['pos.order'].sudo()
        today = fields.Date.context_today(Order)
        if period == 'yesterday':
            first = last = today - timedelta(days=1)
        elif period == 'week':
            first, last = today - timedelta(days=6), today
        elif period == 'month':
            first, last = today.replace(day=1), today
        elif period == 'shift':
            first = last = today
        else:
            period, first, last = 'today', today, today
        domain = [('config_id', '=', config.id), ('state', 'in', ('paid', 'done', 'invoiced'))]
        if period == 'shift':
            live = self._live_session(config)
            domain.append(('session_id', '=', live.id if live else 0))
        else:
            start = datetime.combine(first, time.min) - timedelta(hours=3)  # EAT midnight in UTC
            end = datetime.combine(last, time.min) - timedelta(hours=3) + timedelta(days=1)
            domain += [('date_order', '>=', start), ('date_order', '<', end)]
        orders = Order.search(domain, order='date_order desc')
        by_method, products, by_cashier = {}, {}, {}
        for p in orders.payment_ids:
            by_method[p.payment_method_id.name] = by_method.get(p.payment_method_id.name, 0) + p.amount
        for l in orders.lines:
            row = products.setdefault(l.product_id.id, {'name': l.product_id.display_name, 'qty': 0.0, 'total': 0.0})
            row['qty'] += l.qty
            row['total'] += l.price_subtotal_incl
        for o in orders:
            name = (o.employee_id.name if 'employee_id' in o._fields and o.employee_id else o.user_id.name) or '?'
            row = by_cashier.setdefault(name, {'name': name, 'count': 0, 'total': 0.0})
            row['count'] += 1
            row['total'] += o.amount_total
        days = []
        if period in ('week', 'month'):
            d = first
            while d <= last:
                ds = datetime.combine(d, time.min) - timedelta(hours=3)
                day_orders = orders.filtered(lambda o, ds=ds: ds <= o.date_order < ds + timedelta(days=1))
                days.append({'day': fields.Date.to_string(d), 'total': round(sum(day_orders.mapped('amount_total')), 2),
                             'count': len(day_orders)})
                d += timedelta(days=1)
        return {
            'ok': True, 'period': period, 'from': fields.Date.to_string(first), 'to': fields.Date.to_string(last),
            'count': len(orders), 'total': round(sum(orders.mapped('amount_total')), 2),
            'by_method': [{'method': k, 'amount': round(v, 2)} for k, v in sorted(by_method.items(), key=lambda x: -x[1])],
            'by_cashier': sorted(({'name': v['name'], 'count': v['count'], 'total': round(v['total'], 2)}
                                  for v in by_cashier.values()), key=lambda x: -x['total']),
            'top_products': sorted(({'name': v['name'], 'qty': round(v['qty'], 2), 'total': round(v['total'], 2)}
                                    for v in products.values()), key=lambda x: -x['total'])[:15],
            'days': list(reversed(days)),
            'orders': [self._sale(o) for o in orders[:300]],
        }

    @http.route('/utange/pos/sale', type='json', auth='public', methods=['POST'], csrf=False)
    def sale(self, pin=None, config_id=None, order_id=None, **kw):
        config, _e, _r, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        o = request.env['pos.order'].sudo().browse(int(order_id or 0)).exists()
        if not o:
            return {'ok': False, 'error': 'Sale not found.'}
        return {'ok': True, 'order': self._sale(o, detail=True)}

    @http.route('/utange/pos/stock', type='json', auth='public', methods=['POST'], csrf=False)
    def stock(self, pin=None, config_id=None, **kw):
        config, _e, _r, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        store = config._utange_store_location()
        products = config._utange_products(storable=True)
        here = request.env['utange.stock.sheet'].sudo()._on_hand_for(config, products)
        in_store = {p.id: p.qty_available for p in products.with_context(location=store.id)} if store else {}
        points = config._utange_points()
        return {'ok': True, 'store': store.display_name if store else '',
                'bar': ', '.join('%s: %s' % (label, loc.display_name) for _p, label, loc in points),
                'points': [{'point': pt, 'label': label, 'location': loc.display_name} for pt, label, loc in points],
                'products': [{'id': p.id, 'name': p.display_name, 'uom': p.uom_id.name or '',
                              'point': p.product_tmpl_id._utange_point() or 'main',
                              'point_label': config._utange_point_label(p.product_tmpl_id._utange_point()),
                              'bar': here.get(p.id, (None, 0.0))[1],
                              'store': in_store.get(p.id) if store and store != here.get(p.id, (store, 0))[0] else None}
                             for p in products]}

    # ------------------------------------------------------------------
    # Shift: session + stock sheet
    # ------------------------------------------------------------------
    def _sheet_of(self, session):
        if not session:
            return request.env['utange.stock.sheet']
        return request.env['utange.stock.sheet'].sudo().search([('session_id', '=', session.id), ('state', '!=', 'draft')],
                                                               order='id desc', limit=1)

    def _session_info(self, config, emp=None, role=None):
        session = self._live_session(config)
        last_closed = request.env['pos.session'].sudo().search(
            [('config_id', '=', config.id), ('state', '=', 'closed')], order='stop_at desc, id desc', limit=1)
        sheet = self._sheet_of(session)
        data = {
            'config': config.name,
            'state': session.state if session else 'closed',
            'session': None,
            'opening_suggestion': last_closed.cash_register_balance_end_real or 0.0,
            'last_closed': {'name': last_closed.name, 'stop_at': self._local(last_closed, last_closed.stop_at),
                            'cash': last_closed.cash_register_balance_end_real} if last_closed else None,
            'cash_control': bool(config.cash_control),
            'user': self._pos_user(config, session).name,
            'cashiers_on': self._hr_on(config),
            'cashier': {'name': emp.name, 'role': role} if emp else None,
            'can_close': self._can_close(emp, role, session) if session else False,
            'can_cash_move': (not self._hr_on(config)) or role == 'manager',
            'require_sheet': bool(config.utange_require_sheet),
            'count_at_close': bool(config.utange_count_at_close),
            'sheet': {'id': sheet.id, 'name': sheet.name, 'outside': sheet.opened_outside,
                      'open_diffs': sheet.open_diff_count} if sheet else None,
            'needs_open_count': bool(session and session.state == 'opened' and config.utange_require_sheet and not sheet),
            'sheet_ready': (self._ready_sheet(config).name or '') if (not session or session.state == 'opening_control') else '',
            'close_ready': bool(sheet and sheet.close_confirmed),
        }
        if not session:
            return data
        data['session'] = {
            'id': session.id, 'name': session.name, 'state': session.state, 'user': session.user_id.name or '',
            'start_at': self._local(session, session.start_at),
            'opening_cash': session.cash_register_balance_start,
        }
        if session.state in ('opened', 'closing_control'):
            close = self._as_pos_user(config, session)['pos.session'].browse(session.id).get_closing_control_data()
            cash = close.get('default_cash_details') or None
            drafts = session.order_ids.filtered(lambda o: o.state == 'draft')
            data['closing'] = {
                'orders': close['orders_details']['quantity'],
                'amount': close['orders_details']['amount'],
                'cash': {'name': cash['name'], 'expected': cash['amount'], 'opening': session.cash_register_balance_start,
                         'payments': cash['payment_amount'], 'moves': cash['moves']} if cash else None,
                'other': [{'name': m['name'], 'amount': m['amount'], 'count': m['number']} for m in close['other_payment_methods']],
                'max_difference': close.get('amount_authorized_diff'),
                'drafts': [o.name for o in drafts][:20],
            }
        return data

    @http.route('/utange/pos/session', type='json', auth='public', methods=['POST'], csrf=False)
    def session(self, pin=None, config_id=None, cashier=None, **kw):
        config, emp, role, bad = self._guard(pin, config_id, cashier, need_cashier=False)
        if bad:
            return bad
        return {'ok': True, 'info': self._session_info(config, emp, role)}

    @http.route('/utange/pos/sheet', type='json', auth='public', methods=['POST'], csrf=False)
    def sheet(self, pin=None, config_id=None, cashier=None, phase='open', **kw):
        """Items to count. phase=open: system quantities now; phase=close: expected closing of the shift."""
        config, emp, role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        Sheet = request.env['utange.stock.sheet'].sudo()
        location = config._utange_location()
        if not location:
            return {'ok': False, 'error': 'This POS has no stock location (POS operation type has no source location).'}
        if phase == 'close':
            session = self._live_session(config)
            if not session or session.state not in ('opened', 'closing_control'):
                return {'ok': False, 'error': 'There is no open shift.'}
            sheet = self._sheet_of(session)
            if not sheet:
                sheet = Sheet._start(config, session, {}, outside=True)
            sheet._refresh_movements()
            items = [{'product_id': l.product_id.id, 'name': l.product_id.display_name, 'uom': l.uom_id.name or '',
                      'opening': l.counted_open, 'received': l.received, 'sent_out': l.sent_out, 'sold': l.sold,
                      'expected': l.expected_close, 'price': l.price, 'point': l.point or '',
                      'categ': l.product_id.pos_categ_ids[:1].name or ''} for l in sheet.line_ids]
            return {'ok': True, 'phase': 'close', 'sheet': sheet.name, 'location': self._points_text(config), 'items': items}
        order = {'bar': 0, 'kitchen': 1}
        products = config._utange_sheet_products().sorted(
            lambda p: (order.get(p.product_tmpl_id._utange_point(), 2), p.display_name))
        on_hand = Sheet._on_hand_for(config, products)
        last = Sheet.search([('config_id', '=', config.id), ('state', '=', 'closed')], order='close_date desc, id desc', limit=1)
        last_count = {l.product_id.id: l.counted_close for l in last.line_ids if l.closed} if last else {}
        items = [{'product_id': p.id, 'name': p.display_name, 'uom': p.uom_id.name or '',
                  'system': on_hand.get(p.id, (None, 0.0))[1], 'last_close': last_count.get(p.id),
                  'point': config._utange_point_label(p.product_tmpl_id._utange_point()),
                  'price': Sheet._price_incl(p, config), 'categ': p.pos_categ_ids[:1].name or ''} for p in products]
        return {'ok': True, 'phase': 'open', 'location': self._points_text(config), 'items': items,
                'last_sheet': last.name if last else ''}

    def _points_text(self, config):
        return ' · '.join('%s: %s' % (label, loc.display_name) for _p, label, loc in config._utange_points())

    def _approver(self, config, emp, role, manager_pin):
        """(name or None, error): a manager's PIN typed now, or the signed-in cashier being a manager."""
        if manager_pin:
            mgr, err = config.sudo()._utange_manager_by_pin(manager_pin)
            return (mgr.name, None) if mgr else (None, err)
        if emp and role == 'manager':
            return emp.name, None
        return None, None

    @http.route('/utange/pos/check_manager_pin', type='json', auth='public', methods=['POST'], csrf=False)
    def check_manager_pin(self, pin=None, config_id=None, cashier=None, manager_pin=None, **kw):
        config, emp, role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        mgr, err = config.sudo()._utange_manager_by_pin(manager_pin)
        return {'ok': bool(mgr), 'name': mgr.name if mgr else '', 'error': err or ''}

    def _ready_sheet(self, config):
        """An opening count confirmed in Odoo (or earlier on a handheld) waiting for its session."""
        return request.env['utange.stock.sheet'].sudo().search(
            [('config_id', '=', config.id), ('session_id', '=', False), ('state', '=', 'open')], order='id desc', limit=1)

    def _counts(self, counts):
        out = {}
        for c in (counts or []):
            try:
                out[int(c.get('product_id'))] = _f(c.get('qty'))
            except (TypeError, ValueError):
                continue
        return out

    @http.route('/utange/pos/session_open', type='json', auth='public', methods=['POST'], csrf=False)
    def session_open(self, pin=None, config_id=None, cashier=None, opening_cash=None, notes=None, counts=None,
                     manager_pin=None, reason=None, **kw):
        config, emp, role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        by = (' by %s' % emp.name) if emp else ''
        session = self._live_session(config)
        if session and session.state == 'opened':
            return {'ok': True, 'message': '%s is already open.' % session.name, 'info': self._session_info(config, emp, role)}
        if session and session.state == 'closing_control':
            return {'ok': False, 'error': '%s is being closed. Finish closing it first.' % session.name}
        counted = self._counts(counts)
        Sheet = request.env['utange.stock.sheet'].sudo()
        ready = self._ready_sheet(config) if not counted else Sheet
        if config.utange_require_sheet and not ready:
            needed = config._utange_sheet_products()
            missing = needed.filtered(lambda p: p.id not in counted)
            if missing:
                return {'ok': False, 'error': 'Count every item first: %d not counted (%s).' % (
                    len(missing), ', '.join(missing[:3].mapped('display_name'))), 'count_required': True}
        by, err = self._approver(config, emp, role, manager_pin)
        if err:
            return {'ok': False, 'error': err, 'manager_pin': True}
        env = self._as_pos_user(config, session)
        try:
            # The confirmed sheet exists first, so Odoo lets the session open (see pos_session.py).
            sheet = ready
            if not sheet:
                sheet = Sheet._start(config, None, counted, employee=emp)
                sheet._settle('open', by, reason)
            cfg = env['pos.config'].browse(config.id)
            if not session:
                cfg._check_before_creating_new_session()
                session = env['pos.session'].create({'user_id': env.uid, 'config_id': cfg.id})
            else:
                session = env['pos.session'].browse(session.id)
            if session.state == 'opening_control':
                cash = _f(opening_cash) if opening_cash not in (None, '') else session.cash_register_balance_start
                session.set_cashbox_pos(cash, ((notes or '').strip() + '\n(opened on the Utange handheld%s)' % by).strip())
            if not sheet.session_id:
                sheet.session_id = session.id
        except (UserError, ValidationError, AccessError) as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        self._log_as(session, emp, 'Shift opened on the Utange handheld%s. Stock sheet %s (%d opening differences).'
                     % (by, sheet.name, sheet.open_diff_count))
        return {'ok': True, 'message': '%s is open. Stock sheet %s saved.%s' % (
                    session.name, sheet.name, self._approval_text(sheet.open_approval, sheet.open_approved_by)),
                'approval': sheet.open_approval, 'info': self._session_info(config, emp, role)}

    def _approval_text(self, state, by):
        if state == 'pending':
            return ' Differences sent to the manager for approval.'
        if state == 'approved':
            return ' Differences approved by %s.' % by
        return ''

    @http.route('/utange/pos/sheet_confirm_open', type='json', auth='public', methods=['POST'], csrf=False)
    def sheet_confirm_open(self, pin=None, config_id=None, cashier=None, counts=None, manager_pin=None, reason=None, **kw):
        """The shift was opened in Odoo (POS screen): the cashier counts and confirms the opening stock now."""
        config, emp, role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        session = self._open_session(config)
        if not session:
            return {'ok': False, 'error': 'There is no open shift.'}
        sheet = self._sheet_of(session)
        if sheet:
            return {'ok': True, 'message': 'Stock sheet %s is already confirmed.' % sheet.name,
                    'info': self._session_info(config, emp, role)}
        counted = self._counts(counts)
        missing = config._utange_sheet_products().filtered(lambda p: p.id not in counted)
        if missing:
            return {'ok': False, 'error': 'Count every item first: %d not counted (%s).' % (
                len(missing), ', '.join(missing[:3].mapped('display_name'))), 'count_required': True}
        by, err = self._approver(config, emp, role, manager_pin)
        if err:
            return {'ok': False, 'error': err, 'manager_pin': True}
        sheet = request.env['utange.stock.sheet'].sudo()._start(config, session, counted, employee=emp)
        sheet.message_post(body='Shift opened in Odoo; opening stock counted on the handheld%s.'
                                % ((' by %s' % emp.name) if emp else ''))
        sheet._settle('open', by, reason)
        return {'ok': True, 'message': 'Opening stock confirmed: %s (%d differences).' % (sheet.name, sheet.open_diff_count),
                'info': self._session_info(config, emp, role)}

    @http.route('/utange/pos/cash_move', type='json', auth='public', methods=['POST'], csrf=False)
    def cash_move(self, pin=None, config_id=None, cashier=None, kind=None, amount=None, reason=None, **kw):
        config, emp, role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        if emp and role != 'manager':
            return {'ok': False, 'error': 'Only a POS manager can put in or take out cash (same as Odoo POS).'}
        live = self._open_session(config)
        if not live:
            return {'ok': False, 'error': 'Open the shift first.'}
        amount = round(_f(amount), 2)
        reason = (reason or '').strip()[:120]
        if amount <= 0 or not reason:
            return {'ok': False, 'error': 'Enter the amount and a reason.'}
        kind = 'in' if kind == 'in' else 'out'
        try:
            self._as_pos_user(config, live)['pos.session'].browse(live.id).try_cash_in_out(
                kind, amount, reason, {'translatedType': kind, 'formattedAmount': 'KSh %.2f' % amount})
        except Exception as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e)}
        self._log_as(live, emp, 'Cash %s KSh %.2f: %s%s' % (kind, amount, reason, (' (by %s)' % emp.name) if emp else ''))
        return {'ok': True, 'message': 'Cash %s of KSh %.0f recorded.' % (kind, amount),
                'info': self._session_info(config, emp, role)}

    @http.route('/utange/pos/session_close', type='json', auth='public', methods=['POST'], csrf=False)
    def session_close(self, pin=None, config_id=None, cashier=None, counted_cash=None, notes=None, counts=None,
                      manager_pin=None, reason=None, **kw):
        config, emp, role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        live = self._live_session(config)
        if not live or live.state not in ('opened', 'closing_control'):
            return {'ok': False, 'error': 'There is no open shift to close.'}
        if not self._can_close(emp, role, live):
            return {'ok': False, 'error': 'Only a POS manager can close the shift (same as Odoo POS). '
                                          '%s is a cashier: switch to a manager.' % emp.name}
        by = (' by %s' % emp.name) if emp else ''
        info = self._session_info(config, emp, role)
        closing = info.get('closing') or {}
        if closing.get('drafts'):
            return {'ok': False, 'error': 'Unpaid POS orders are still open: %s. Pay or cancel them in Odoo POS first.'
                    % ', '.join(closing['drafts'])}
        Sheet = request.env['utange.stock.sheet'].sudo()
        sheet = self._sheet_of(live) or Sheet._start(config, live, {}, outside=True)
        counted = self._counts(counts)
        done_in_odoo = sheet.close_confirmed and not counted
        if config.utange_count_at_close and not done_in_odoo:
            missing = sheet.line_ids.filtered(lambda l: l.product_id.id not in counted)
            if missing:
                return {'ok': False, 'error': 'Count every item first: %d not counted (%s).' % (
                    len(missing), ', '.join(missing[:3].mapped('product_id.display_name'))), 'count_required': True}
        cash = closing.get('cash')
        if cash:
            if counted_cash in (None, ''):
                return {'ok': False, 'error': 'Count the cash in the drawer and enter it.'}
            diff = round(_f(counted_cash) - cash['expected'], 2)
            limit = closing.get('max_difference')
            if limit is not None and abs(diff) > limit + 0.001:
                return {'ok': False, 'error': 'Cash difference KSh %.0f is more than the KSh %.0f allowed. '
                                              'Recount, or a manager closes it in Odoo.' % (diff, limit)}
        by, err = self._approver(config, emp, role, manager_pin)
        if err:
            return {'ok': False, 'error': err, 'manager_pin': True}
        # 1) the closing count is saved first (kept even if Odoo cannot close the session)
        if not done_in_odoo:
            sheet._finish(counted, employee=emp)
            sheet._settle('close', by, reason)
        request.env.cr.commit()
        env = self._as_pos_user(config, live)
        session = env['pos.session'].browse(live.id)
        try:
            if cash:
                res = session.post_closing_cash_details(_f(counted_cash))
                if not res.get('successful'):
                    return {'ok': False, 'error': res.get('message') or 'Odoo did not accept the closing cash.'}
            session.update_closing_control_state_session(
                ((notes or '').strip() + '\n(closed on the Utange handheld%s)' % by).strip())
            res = session.close_session_from_ui()
            if not res.get('successful'):
                request.env.cr.rollback()
                return {'ok': False, 'error': (res.get('message') or 'Odoo could not close the session.')
                        + ' The stock count is saved. Close the session in Odoo (Point of Sale > Sessions).'}
        except (UserError, ValidationError, AccessError) as e:
            request.env.cr.rollback()
            return {'ok': False, 'error': _err(e) + ' (The stock count is saved.)'}
        sheet = sheet.browse(sheet.id)
        sheet.state = 'closed'
        closed = request.env['pos.session'].sudo().browse(live.id)
        self._log_as(closed, emp, 'Shift closed on the Utange handheld%s. Stock sheet %s: %d closing differences.'
                     % (by, sheet.name, sheet.close_diff_count))
        short = [{'name': l.product_id.display_name, 'diff': l.close_diff}
                 for l in sheet.line_ids if l.closed and abs(l.close_diff) > 0.0001][:30]
        return {'ok': True, 'message': '%s is closed.%s' % (
                    closed.name, self._approval_text(sheet.close_approval, sheet.close_approved_by)),
                'approval': sheet.close_approval,
                'summary': {'name': closed.name, 'orders': closing.get('orders', 0), 'amount': closing.get('amount', 0),
                            'cash_expected': cash['expected'] if cash else None,
                            'cash_counted': closed.cash_register_balance_end_real if cash else None,
                            'difference': round(closed.cash_register_balance_end_real - cash['expected'], 2) if cash else None,
                            'sheet': sheet.name, 'stock_diffs': short,
                            'stock_variance': round(sheet.close_diff_value, 2)},
                'info': self._session_info(config, None, None)}

    # ------------------------------------------------------------------
    # Requisitions: the bar asks the store
    # ------------------------------------------------------------------
    def _req(self, r):
        return {
            'id': r.id, 'name': r.name, 'date': self._local(r, r.date), 'state': r.state,
            'state_label': dict(r._fields['state'].selection).get(r.state, r.state),
            'by': r.employee_id.name or '', 'from': r.location_src_id.display_name, 'to': r.location_dest_id.display_name,
            'point': r.point, 'point_label': dict(r._fields['point'].selection).get(r.point, ''),
            'note': r.note or '', 'manager_note': r.manager_note or '', 'transfer': r.picking_id.name or '',
            'lines': [{'name': l.product_id.display_name, 'qty': l.qty, 'issued': l.qty_issued, 'uom': l.uom_id.name or ''}
                      for l in r.line_ids],
        }

    @http.route('/utange/pos/requisitions', type='json', auth='public', methods=['POST'], csrf=False)
    def requisitions(self, pin=None, config_id=None, **kw):
        config, _e, _r, bad = self._guard(pin, config_id, need_cashier=False)
        if bad:
            return bad
        reqs = request.env['utange.requisition'].sudo().search([('config_id', '=', config.id)], order='id desc', limit=40)
        return {'ok': True, 'requisitions': [self._req(r) for r in reqs]}

    @http.route('/utange/pos/requisition_create', type='json', auth='public', methods=['POST'], csrf=False)
    def requisition_create(self, pin=None, config_id=None, cashier=None, lines=None, note=None, uid=None, point=None, **kw):
        config, emp, _role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        point = point if point in ('bar', 'kitchen') else 'main'
        bar = config._utange_point_location(point)
        store = config._utange_store_location()
        if not bar or not store:
            return {'ok': False, 'error': 'Stock locations are not set for this POS. Ask the manager (Handheld settings).'}
        if bar == store:
            return {'ok': False, 'error': 'The %s and the main store are the same location. Set the Bar / Kitchen / Main store '
                                          'locations in Point of Sale > Handheld > Handheld settings.' % config._utange_point_label(point)}
        Req = request.env['utange.requisition'].sudo()
        uid = str(uid or '').strip()[:60]
        if uid:
            done = Req.search([('config_id', '=', config.id), ('note', 'like', '[%s]' % uid)], limit=1)
            if done:
                return {'ok': True, 'requisition': self._req(done)}
        allowed = config._utange_products(storable=True)
        allowed_ids = set(allowed.ids)
        Product = request.env['product.product'].sudo()
        vals = []
        for l in (lines or [])[:100]:
            p = Product.browse(int(l.get('product_id') or 0)).exists()
            qty = _f(l.get('qty'))
            if p and p.id in allowed_ids and qty > 0:
                vals.append((p, qty, str(l.get('note') or '')[:120]))
        if not vals:
            return {'ok': False, 'error': 'Add at least one item with a quantity.'}
        prods = Product.browse([v[0].id for v in vals])
        in_bar = {p.id: p.qty_available for p in prods.with_context(location=bar.id)}
        in_store = {p.id: p.qty_available for p in prods.with_context(location=store.id)}
        r = Req.create({
            'config_id': config.id,
            'session_id': self._open_session(config).id if self._open_session(config) else False,
            'employee_id': emp.id if emp else False,
            'location_src_id': store.id,
            'location_dest_id': bar.id,
            'point': point,
            'note': ((note or '').strip()[:500] + ('\n[%s]' % uid if uid else '')).strip(),
            'line_ids': [(0, 0, {'product_id': p.id, 'qty': q, 'note': n, 'bar_qty': in_bar.get(p.id, 0.0),
                                 'store_qty': in_store.get(p.id, 0.0)}) for p, q, n in vals],
        })
        return {'ok': True, 'message': '%s sent to the manager for approval.' % r.name, 'requisition': self._req(r)}

    @http.route('/utange/pos/requisition_cancel', type='json', auth='public', methods=['POST'], csrf=False)
    def requisition_cancel(self, pin=None, config_id=None, cashier=None, requisition_id=None, **kw):
        config, emp, _role, bad = self._guard(pin, config_id, cashier)
        if bad:
            return bad
        r = request.env['utange.requisition'].sudo().browse(int(requisition_id or 0)).exists()
        if not r or r.config_id != config:
            return {'ok': False, 'error': 'Requisition not found.'}
        try:
            r.action_cancel()
        except UserError as e:
            return {'ok': False, 'error': _err(e)}
        self._log_as(r, emp, 'Cancelled on the handheld%s.' % ((' by %s' % emp.name) if emp else ''))
        return {'ok': True, 'message': '%s cancelled.' % r.name, 'requisition': self._req(r)}
