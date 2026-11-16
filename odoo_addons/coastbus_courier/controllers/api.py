"""JSON API for the Coast Bus Courier handhelds.

Terminals work offline: everything they do is an *event* with a uuid. /sync takes a batch of events
(processed in order, each in its own savepoint, safe to resend) and returns what changed for the
terminal's branch since its last pull.
"""
import base64
import hashlib
import json
import logging
import secrets
from datetime import timedelta

from odoo import fields, http
from odoo.exceptions import UserError, ValidationError
from odoo.http import request

_logger = logging.getLogger(__name__)
API = '/courier/api/v1'


class Retry(Exception):
    """Not an error yet: e.g. the waybill was booked on another terminal that has not synced. Keep the event and resend later."""


def _json(data, status=200):
    return request.make_response(json.dumps(data, default=str), headers=[('Content-Type', 'application/json')], status=status)


def _body():
    try:
        return json.loads(request.httprequest.get_data() or b'{}')
    except ValueError:
        return {}


def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class CourierApi(http.Controller):

    # ------------------------------------------------------------------ helpers
    def _device(self):
        auth = request.httprequest.headers.get('Authorization', '')
        token = auth[7:] if auth.startswith('Bearer ') else ''
        if '.' not in token:
            return None
        did = token.split('.', 1)[0]
        if not did.isdigit():
            return None
        dev = request.env['courier.device'].sudo().browse(int(did)).exists()
        if not dev or not dev.active or not dev.activated or dev.token_hash != _hash(token):
            return None
        now = fields.Datetime.now()
        if not dev.last_seen or now - dev.last_seen > timedelta(minutes=2):
            dev.last_seen = now
        return dev

    def _denied(self):
        return _json({'ok': False, 'error': 'This terminal is not activated or was switched off in Odoo.', 'code': 'unauthorized'}, 401)

    def _staff(self, sid):
        st = request.env['courier.staff'].sudo().browse(int(sid or 0)).exists()
        if not st or not st.active:
            raise UserError('Unknown or inactive staff member.')
        return st

    # ------------------------------------------------------------------ activation
    @http.route(API + '/ping', type='http', auth='public', methods=['GET'], csrf=False)
    def ping(self):
        return _json({'ok': True, 'app': 'coastbus_courier', 'server_time': fields.Datetime.to_string(fields.Datetime.now())})

    @http.route(API + '/activate', type='http', auth='public', methods=['POST'], csrf=False)
    def activate(self):
        b = _body()
        key = (b.get('key') or '').strip().upper().replace('-', '').replace(' ', '')
        dev = request.env['courier.device'].sudo().search([('activation_key', '=', key), ('active', '=', True)], limit=1) if key else None
        if not dev:
            return _json({'ok': False, 'error': 'Activation key not found. Check it in Odoo: Courier → Configuration → Terminals.'}, 404)
        if dev.activated:
            return _json({'ok': False, 'error': 'This key was already used. In Odoo press "New key" on the terminal.'}, 409)
        token = f'{dev.id}.{secrets.token_urlsafe(32)}'
        dev.write({'token_hash': _hash(token), 'activated': True, 'device_uid': b.get('device_uid') or '', 'model_name': b.get('model') or '',
                   'app_version': b.get('app_version') or '', 'last_seen': fields.Datetime.now(), 'activation_key': False})
        return _json({'ok': True, 'token': token, 'device': {'id': dev.id, 'number': dev.number, 'name': dev.name, 'hub_id': dev.hub_id.id}})

    # ------------------------------------------------------------------ master data
    @http.route(API + '/bootstrap', type='http', auth='public', methods=['GET'], csrf=False)
    def bootstrap(self):
        dev = self._device()
        if not dev:
            return self._denied()
        env = request.env
        cfg = env['courier.config'].get_cfg()
        company = env.company.sudo()
        hubs = env['courier.hub'].sudo().search([])
        routes = env['courier.route'].sudo().search([])
        staff = env['courier.staff'].sudo().search([])
        logo = ''
        # Odoo's placeholder ("Your logo") is not printed: only a logo uploaded for the company
        default_logo = company._get_logo() if hasattr(company, '_get_logo') else b''
        own = company.logo and (company.logo if isinstance(company.logo, bytes) else company.logo.encode()) != (
            default_logo if isinstance(default_logo, bytes) else (default_logo or '').encode())
        if own and company.logo_web:
            logo = company.logo_web.decode() if isinstance(company.logo_web, bytes) else company.logo_web
        # numbering continues after a reinstall: highest number this terminal already used
        pre = f"{cfg['wb_prefix']}-{dev.hub_id.code}-{dev.number:02d}-"
        last_w = env['courier.waybill'].sudo().search([('name', '=like', pre + '%')], order='name desc', limit=1)
        mpre = f'MNF-{dev.hub_id.code}-{dev.number:02d}-'
        last_m = env['courier.manifest'].sudo().search([('name', '=like', mpre + '%')], order='name desc', limit=1)
        seq = lambda rec, p: int(rec.name[len(p):]) if rec and rec.name[len(p):].isdigit() else 0
        return _json({
            'ok': True, 'server_time': fields.Datetime.to_string(fields.Datetime.now()),
            'device': {'id': dev.id, 'number': dev.number, 'name': dev.name, 'hub_id': dev.hub_id.id,
                       'last_waybill_seq': seq(last_w, pre), 'last_manifest_seq': seq(last_m, mpre)},
            'company': {'name': company.name, 'phone': company.phone or '', 'email': company.email or '', 'vat': company.vat or '',
                        'street': ', '.join(x for x in [company.street, company.city] if x), 'currency': company.currency_id.name, 'logo': logo},
            'cfg': cfg,
            'hubs': [{'id': h.id, 'name': h.name, 'code': h.code, 'phone': h.phone or '', 'address': h.address or ''} for h in hubs],
            'routes': [{'id': r.id, 'origin_hub_id': r.origin_hub_id.id, 'destination_hub_id': r.destination_hub_id.id, 'base_fare': r.base_fare,
                        'base_kg': r.base_kg, 'rate_per_kg': r.rate_per_kg, 'extra_piece_fee': r.extra_piece_fee, 'min_charge': r.min_charge,
                        'both_ways': r.both_ways} for r in routes],
            'vehicles': [{'id': v.id, 'name': v.name, 'description': v.description or ''} for v in env['courier.vehicle'].sudo().search([])],
            'staff': [{'id': s.id, 'name': s.name, 'code': s.code or '', 'role': s.role, 'hub_id': s.hub_id.id or 0, 'phone': s.phone or '',
                       'pin_hash': s.pin_hash or '', 'pin_salt': s.pin_salt or '', 'active': s.active} for s in staff],
            'accounts': [{'id': p.id, 'name': p.name, 'phone': p.phone or ''}
                         for p in env['res.partner'].sudo().search([('courier_account', '=', True)], order='name')],
        })

    # ------------------------------------------------------------------ sync
    @http.route(API + '/sync', type='http', auth='public', methods=['POST'], csrf=False)
    def sync(self):
        dev = self._device()
        if not dev:
            return self._denied()
        b = _body()
        results = []
        for ev in b.get('events') or []:
            results.append(self._process(dev, ev))
        pulled = self._pull(dev, b.get('since') or '')
        return _json({'ok': True, 'results': results, **pulled})

    def _process(self, dev, ev):
        Event = request.env['courier.event'].sudo()
        uuid = ev.get('uuid')
        kind = ev.get('kind')
        if not uuid or not kind:
            return {'uuid': uuid, 'ok': False, 'error': 'Missing uuid/kind'}
        done = Event.search([('uuid', '=', uuid)], limit=1)
        if done:
            return {'uuid': uuid, 'ok': done.ok, 'error': done.error or '', 'dup': True}
        try:
            with request.env.cr.savepoint():
                info = self._apply(dev, kind, ev.get('data') or {}, uuid)
            Event.create({'uuid': uuid, 'kind': kind, 'device_id': dev.id, 'staff_id': (ev.get('data') or {}).get('staff_id') or False,
                          'payload': json.dumps(ev.get('data'))[:20000], 'ok': True})
            return {'uuid': uuid, 'ok': True, **(info or {})}
        except Retry as e:
            return {'uuid': uuid, 'ok': False, 'retry': True, 'error': str(e)}
        except (UserError, ValidationError) as e:
            msg = e.args[0] if e.args else str(e)
        except Exception as e:  # keep the queue moving; the problem is visible in Odoo and on the terminal
            _logger.exception('Courier event %s (%s) failed', uuid, kind)
            msg = f'Server error: {e}'
        Event.create({'uuid': uuid, 'kind': kind, 'device_id': dev.id, 'payload': json.dumps(ev.get('data'))[:20000], 'ok': False, 'error': msg[:250]})
        return {'uuid': uuid, 'ok': False, 'error': msg}

    def _waybill(self, d):
        Wb = request.env['courier.waybill'].sudo()
        no = (d.get('waybill') or '').strip().upper()
        w = Wb.search([('name', '=', no)], limit=1) if no else Wb
        if not w:
            raise Retry(f'Waybill {no} not on the server yet (booked on a terminal that has not synced).')
        return w

    def _manifest(self, d):
        M = request.env['courier.manifest'].sudo()
        m = M.search(['|', ('client_uuid', '=', d.get('manifest_uuid') or '-'), ('name', '=', d.get('manifest') or '-')], limit=1)
        if not m:
            raise Retry(f'Manifest {d.get("manifest")} not on the server yet.')
        return m

    def _apply(self, dev, kind, d, uuid):
        env = request.env
        staff = self._staff(d.get('staff_id'))
        at = d.get('at') or fields.Datetime.to_string(fields.Datetime.now())
        if kind == 'book':
            d['uuid'] = d.get('uuid') or uuid
            w = env['courier.waybill'].sudo().book_from_terminal(d, dev, staff)
            return {'waybill_id': w.id}
        if kind == 'cancel':
            self._waybill(d).cancel_from_terminal(staff, dev, d.get('reason') or '', uuid)
            return {}
        if kind == 'manifest_open':
            d['uuid'] = d.get('uuid') or uuid
            m = env['courier.manifest'].sudo().open_from_terminal(d, dev, staff)
            return {'manifest_id': m.id}
        if kind == 'load':
            self._manifest(d).load_piece(self._waybill(d), int(d.get('piece') or 1), staff, dev, at, uuid)
            return {}
        if kind == 'unload':
            self._manifest(d).unload_piece(self._waybill(d), int(d.get('piece') or 1), staff, dev, at, uuid)
            return {}
        if kind == 'depart':
            self._manifest(d).depart(staff, dev, at)
            return {}
        if kind == 'offload':
            self._manifest(d).offload_piece(self._waybill(d), int(d.get('piece') or 1), staff, dev, at, uuid)
            return {}
        if kind == 'receive_complete':
            short = self._manifest(d).receive_complete(d, staff, dev)
            return {'shortages': len(short)}
        if kind == 'collect':
            d['uuid'] = uuid
            self._waybill(d).collect_from_terminal(d, staff, dev)
            return {}
        raise UserError(f'Unknown event {kind}')

    def _pull(self, dev, since):
        env = request.env
        now = fields.Datetime.now()
        hub = dev.hub_id
        Wb = env['courier.waybill'].sudo()
        M = env['courier.manifest'].sudo()
        if since:
            try:
                since_dt = fields.Datetime.to_datetime(since) - timedelta(seconds=5)
            except Exception:
                since_dt = now - timedelta(days=14)
        else:
            since_dt = now - timedelta(days=14)
        mdom = [('write_date', '>=', since_dt), '|', '|', ('origin_hub_id', '=', hub.id), ('destination_hub_id', '=', hub.id),
                ('line_ids.destination_hub_id', '=', hub.id)]
        if not since:
            mdom = [('state', 'in', ('loading', 'in_transit'))] + mdom[1:]
        manifests = M.search(mdom, limit=200)
        wdom = [('write_date', '>=', since_dt), '|', '|', '|', ('origin_hub_id', '=', hub.id), ('destination_hub_id', '=', hub.id),
                ('current_hub_id', '=', hub.id), ('manifest_id', 'in', manifests.ids)]
        waybills = Wb.search(wdom, limit=2000, order='id')
        waybills |= manifests.mapped('line_ids.waybill_id')
        return {'since': fields.Datetime.to_string(now), 'waybills': waybills.to_terminal(), 'manifests': manifests.to_terminal()}

    # ------------------------------------------------------------------ online lookups
    @http.route(API + '/waybill', type='http', auth='public', methods=['GET'], csrf=False)
    def waybill(self, q='', **kw):
        dev = self._device()
        if not dev:
            return self._denied()
        q = (q or '').strip()
        Wb = request.env['courier.waybill'].sudo()
        base = q.upper().split('/')[0]
        w = Wb.search([('name', '=', base)], limit=1) or Wb.search([('tracking_token', '=', q.rsplit('/', 1)[-1])], limit=1)
        if not w and q:
            from ..models.common import norm_phone
            ph = norm_phone(q)
            found = Wb.search(['|', ('receiver_phone', '=', ph), ('sender_phone', '=', ph)], limit=20)
            return _json({'ok': True, 'many': found.to_terminal()})
        if not w:
            return _json({'ok': False, 'error': 'Not found'}, 404)
        scans = [{'kind': s.kind, 'at': fields.Datetime.to_string(s.scanned_at), 'hub': s.hub_id.name or '', 'by': s.staff_id.name or '',
                  'piece': s.piece, 'manifest': s.manifest_id.name or '', 'result': s.result, 'note': s.note or ''} for s in w.scan_ids.sorted('scanned_at')]
        return _json({'ok': True, 'waybill': w.to_terminal()[0], 'scans': scans})

    @http.route(API + '/manifest', type='http', auth='public', methods=['GET'], csrf=False)
    def manifest(self, q='', **kw):
        dev = self._device()
        if not dev:
            return self._denied()
        m = request.env['courier.manifest'].sudo().search([('name', '=', (q or '').strip().upper())], limit=1)
        if not m:
            return _json({'ok': False, 'error': 'Manifest not found on the server.'}, 404)
        return _json({'ok': True, 'manifest': m.to_terminal()[0], 'waybills': m.line_ids.waybill_id.to_terminal()})

    # ------------------------------------------------------------------ M-Pesa STK
    @http.route(API + '/mpesa/stk', type='http', auth='public', methods=['POST'], csrf=False)
    def stk(self):
        dev = self._device()
        if not dev:
            return self._denied()
        b = _body()
        try:
            staff = self._staff(b.get('staff_id'))
            rec = request.env['courier.mpesa'].sudo().start(b.get('phone'), float(b.get('amount') or 0), b.get('ref'), dev, staff)
        except UserError as e:
            return _json({'ok': False, 'error': e.args[0]}, 400)
        return _json({'ok': True, 'id': rec.id})

    @http.route(API + '/mpesa/status', type='http', auth='public', methods=['GET'], csrf=False)
    def stk_status(self, id=0, **kw):
        dev = self._device()
        if not dev:
            return self._denied()
        rec = request.env['courier.mpesa'].sudo().browse(int(id or 0)).exists()
        if not rec or rec.device_id != dev:
            return _json({'ok': False, 'error': 'Not found'}, 404)
        if rec.state == 'pending' and rec.create_date and fields.Datetime.now() - rec.create_date > timedelta(seconds=25):
            rec.query()
        return _json({'ok': True, 'state': rec.state, 'receipt': rec.receipt or '', 'desc': rec.result_desc or ''})

    @http.route('/courier/mpesa/callback', type='http', auth='public', methods=['POST'], csrf=False)
    def stk_callback(self):
        try:
            request.env['courier.mpesa'].sudo().callback(_body())
        except Exception:
            _logger.exception('M-Pesa callback failed')
        return _json({'ResultCode': 0, 'ResultDesc': 'Accepted'})
