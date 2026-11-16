import logging
import secrets

from odoo import _, api, fields, models
from odoo.exceptions import UserError

from .common import charge, mask_name, norm_phone, otp_hash

_logger = logging.getLogger(__name__)

STATES = [
    ('booked', 'Booked (at origin)'),
    ('loaded', 'Loaded on vehicle'),
    ('in_transit', 'In transit'),
    ('at_hub', 'At transfer branch'),
    ('arrived', 'Arrived – ready for collection'),
    ('collected', 'Collected'),
    ('lost', 'Missing / lost in transit'),
    ('cancelled', 'Cancelled'),
]
PAY_MODES = [
    ('cash', 'Cash'),
    ('mpesa_code', 'M-Pesa (code)'),
    ('mpesa_stk', 'M-Pesa (STK push)'),
    ('account', 'Account / credit'),
    ('receiver', 'Pay on collection'),
]


class CourierWaybill(models.Model):
    _name = 'courier.waybill'
    _description = 'Waybill'
    _inherit = ['mail.thread', 'mail.activity.mixin']
    _order = 'booked_at desc, id desc'
    _rec_names_search = ['name', 'sender_phone', 'receiver_phone', 'receiver_name', 'sender_name']

    name = fields.Char('Waybill no.', required=True, copy=False, index=True, tracking=True)
    client_uuid = fields.Char(copy=False, index=True)
    tracking_token = fields.Char(copy=False, index=True, default=lambda s: secrets.token_urlsafe(8))
    state = fields.Selection(STATES, default='booked', required=True, tracking=True, index=True)
    origin_hub_id = fields.Many2one('courier.hub', 'From', required=True, index=True)
    destination_hub_id = fields.Many2one('courier.hub', 'To', required=True, index=True, tracking=True)
    current_hub_id = fields.Many2one('courier.hub', 'Now at', tracking=True)
    route_id = fields.Many2one('courier.route')
    company_id = fields.Many2one('res.company', default=lambda s: s.env.company)
    currency_id = fields.Many2one(related='company_id.currency_id')

    sender_name = fields.Char(required=True)
    sender_phone = fields.Char(required=True)
    sender_id_no = fields.Char('Sender ID no.')
    sender_partner_id = fields.Many2one('res.partner', 'Sender contact')
    receiver_name = fields.Char(required=True)
    receiver_phone = fields.Char(required=True, index=True)
    receiver_partner_id = fields.Many2one('res.partner', 'Receiver contact')

    description = fields.Char('Contents', required=True)
    pieces = fields.Integer(default=1)
    weight = fields.Float('Weight (kg)', digits=(10, 2))
    length = fields.Float('L (cm)')
    width = fields.Float('W (cm)')
    height = fields.Float('H (cm)')
    vol_weight = fields.Float('Volumetric (kg)', digits=(10, 2))
    chargeable_weight = fields.Float('Chargeable (kg)', digits=(10, 2))
    declared_value = fields.Monetary()
    insured = fields.Boolean()
    fragile = fields.Boolean()

    fare = fields.Monetary('Freight')
    insurance = fields.Monetary()
    total = fields.Monetary(tracking=True)
    vat_amount = fields.Monetary('VAT included')
    price_note = fields.Char('Price check', readonly=True,
                             help='Filled when the terminal charged a different amount than the current tariff (e.g. tariff changed while offline).')
    payment_mode = fields.Selection(PAY_MODES, required=True, default='cash')
    payment_ref = fields.Char('Payment ref', index=True)
    paid = fields.Boolean(tracking=True)
    account_partner_id = fields.Many2one('res.partner', 'Account customer')
    invoice_id = fields.Many2one('account.move', readonly=True, copy=False)
    invoice_error = fields.Char(readonly=True, copy=False)

    otp = fields.Char('Collection code', copy=False, groups='base.group_system')
    otp_hash = fields.Char(copy=False, groups='base.group_system')
    booked_at = fields.Datetime(default=fields.Datetime.now, index=True)
    booked_by_id = fields.Many2one('courier.staff', 'Booked by')
    device_id = fields.Many2one('courier.device', 'Terminal')
    manifest_id = fields.Many2one('courier.manifest', 'Current manifest', copy=False)
    custodian_id = fields.Many2one('courier.staff', 'Custodian (driver)', tracking=True, copy=False)
    vehicle_id = fields.Many2one('courier.vehicle', copy=False)
    arrived_at = fields.Datetime(copy=False)
    collected_at = fields.Datetime(copy=False)
    collected_by_name = fields.Char('Collected by', copy=False)
    collected_id_no = fields.Char('Collector ID no.', copy=False)
    collected_staff_id = fields.Many2one('courier.staff', 'Released by', copy=False)
    collect_method = fields.Selection([('otp', 'OTP'), ('override', 'ID + supervisor')], copy=False)
    scan_ids = fields.One2many('courier.scan', 'waybill_id', 'Custody log')
    sms_ids = fields.One2many('courier.sms', 'waybill_id', 'SMS')
    discrepancy_ids = fields.One2many('courier.discrepancy', 'waybill_id')
    note = fields.Text()
    track_link = fields.Char(compute='_compute_track_link')
    days_waiting = fields.Integer(compute='_compute_days_waiting')

    _sql_constraints = [
        ('name_uniq', 'unique(name)', 'This waybill number already exists.'),
        ('uuid_uniq', 'unique(client_uuid)', 'Duplicate terminal record.'),
    ]

    def _compute_track_link(self):
        base = self.env['courier.config'].get_cfg()['track_url']
        for w in self:
            w.track_link = base + (w.tracking_token or '')

    def _compute_days_waiting(self):
        now = fields.Datetime.now()
        for w in self:
            w.days_waiting = (now - w.arrived_at).days if w.state == 'arrived' and w.arrived_at else 0

    # ------------------------------------------------------------------ booking
    @api.model
    def _partner_for(self, name, phone):
        phone = norm_phone(phone)
        p = self.env['res.partner'].sudo().search(['|', ('phone', '=', phone), ('mobile', '=', phone)], limit=1)
        if not p:
            p = self.env['res.partner'].sudo().create({'name': name or phone, 'phone': phone, 'mobile': phone})
        return p

    @api.model
    def book_from_terminal(self, d, device, staff):
        """Waybill made on a handheld (possibly offline hours ago). Idempotent on client uuid."""
        existing = self.sudo().search([('client_uuid', '=', d['uuid'])], limit=1)
        if existing:
            return existing
        Hub = self.env['courier.hub'].sudo()
        origin = Hub.browse(int(d['origin_hub_id'])).exists() or device.hub_id
        dest = Hub.browse(int(d['destination_hub_id'])).exists()
        if not dest:
            raise UserError(_('Unknown destination branch.'))
        name = (d.get('name') or '').strip().upper()
        if not name:
            raise UserError(_('Waybill number missing.'))
        if self.sudo().search_count([('name', '=', name)]):
            raise UserError(_('Waybill number %s is already used.') % name)
        route = self.env['courier.route'].sudo().find(origin, dest)
        cfg = self.env['courier.config'].get_cfg()
        vals = {
            'name': name, 'client_uuid': d['uuid'], 'tracking_token': d.get('tracking_token') or secrets.token_urlsafe(8),
            'origin_hub_id': origin.id, 'destination_hub_id': dest.id, 'current_hub_id': origin.id,
            'route_id': route.id or False,
            'sender_name': d['sender_name'].strip(), 'sender_phone': norm_phone(d['sender_phone']), 'sender_id_no': d.get('sender_id_no') or '',
            'receiver_name': d['receiver_name'].strip(), 'receiver_phone': norm_phone(d['receiver_phone']),
            'description': d.get('description') or '-', 'pieces': max(1, int(d.get('pieces') or 1)),
            'weight': float(d.get('weight') or 0), 'length': float(d.get('length') or 0), 'width': float(d.get('width') or 0),
            'height': float(d.get('height') or 0), 'declared_value': float(d.get('declared_value') or 0),
            'insured': bool(d.get('insured')), 'fragile': bool(d.get('fragile')),
            'fare': float(d.get('fare') or 0), 'insurance': float(d.get('insurance') or 0), 'total': float(d.get('total') or 0),
            'vol_weight': float(d.get('vol_weight') or 0), 'chargeable_weight': float(d.get('chargeable_weight') or 0),
            'vat_amount': float(d.get('vat_amount') or 0),
            'payment_mode': d.get('payment_mode') or 'cash', 'payment_ref': (d.get('payment_ref') or '').strip().upper(),
            'booked_at': d.get('booked_at') or fields.Datetime.now(), 'booked_by_id': staff.id, 'device_id': device.id,
            'note': d.get('note') or '',
        }
        vals['paid'] = vals['payment_mode'] in ('cash', 'mpesa_code', 'mpesa_stk')
        if vals['payment_mode'] == 'account':
            acc = self.env['res.partner'].sudo().browse(int(d.get('account_partner_id') or 0)).exists()
            if not acc:
                raise UserError(_('Choose the account customer.'))
            vals['account_partner_id'] = acc.id
        if route:
            want = charge(route, cfg, vals['weight'], vals['length'], vals['width'], vals['height'],
                          vals['declared_value'], vals['insured'], vals['pieces'])
            if abs(want['total'] - vals['total']) > 0.5:
                vals['price_note'] = _('Tariff now gives %(want).2f, terminal charged %(got).2f') % {'want': want['total'], 'got': vals['total']}
        vals['sender_partner_id'] = self._partner_for(vals['sender_name'], vals['sender_phone']).id
        vals['receiver_partner_id'] = self._partner_for(vals['receiver_name'], vals['receiver_phone']).id
        w = self.sudo().create(vals)
        if d.get('otp'):
            w.sudo().write({'otp': str(d['otp']), 'otp_hash': otp_hash(str(d['otp']), w.name)})
        w._log_scan('book', hub=origin, staff=staff, device=device, at=vals['booked_at'], uuid=d['uuid'] + ':book')
        w._try_invoice()
        cfg_on = self.env['courier.config'].get_cfg()
        if cfg_on['sms_sender_notice']:
            w._queue_sms('booked_sender')
        if cfg_on['sms_receiver_notice']:
            w._queue_sms('booked_receiver')
        return w

    def _log_scan(self, kind, hub=None, staff=None, device=None, at=None, uuid=None, piece=0, manifest=None, result='ok', note=''):
        Scan = self.env['courier.scan'].sudo()
        for w in self:
            if uuid and Scan.search_count([('client_uuid', '=', uuid)]):
                continue
            Scan.create({'waybill_id': w.id, 'kind': kind, 'hub_id': hub.id if hub else False, 'staff_id': staff.id if staff else False,
                         'device_id': device.id if device else False, 'scanned_at': at or fields.Datetime.now(), 'client_uuid': uuid,
                         'piece': piece, 'manifest_id': manifest.id if manifest else False, 'result': result, 'note': note})

    # ------------------------------------------------------------------ accounting
    def _freight_product(self):
        p = self.env.ref('coastbus_courier.product_courier_freight', raise_if_not_found=False)
        return p

    def _insurance_product(self):
        return self.env.ref('coastbus_courier.product_courier_insurance', raise_if_not_found=False)

    def _try_invoice(self):
        for w in self:
            if w.invoice_id or w.total <= 0 or w.payment_mode == 'receiver':
                continue
            try:
                with self.env.cr.savepoint():
                    w._make_invoice()
                w.invoice_error = False
            except Exception as e:  # never block the terminal sync because of accounting setup
                _logger.warning('Courier invoice for %s failed: %s', w.name, e)
                w.invoice_error = str(e)[:250]

    def _make_invoice(self):
        self.ensure_one()
        w = self.sudo()
        partner = w.account_partner_id or w.sender_partner_id
        lines = []
        fp, ip = w._freight_product(), w._insurance_product()
        # prices on the terminals include VAT: only a "price included" tax chosen in Courier settings is used
        tid = int(self.env['ir.config_parameter'].sudo().get_param('coastbus.tax_id') or 0)
        tax = self.env['account.tax'].sudo().browse(tid).exists()
        taxes = [(6, 0, tax.ids)]
        label = f'{w.name} {w.origin_hub_id.code}→{w.destination_hub_id.code} · {w.description} · {w.chargeable_weight or w.weight} kg'
        lines.append((0, 0, {'product_id': fp.id if fp else False, 'name': label, 'quantity': 1, 'price_unit': w.fare, 'tax_ids': taxes}))
        if w.insurance:
            lines.append((0, 0, {'product_id': ip.id if ip else False, 'name': _('Insurance %s') % w.name, 'quantity': 1,
                                 'price_unit': w.insurance, 'tax_ids': taxes}))
        move = self.env['account.move'].sudo().create({
            'move_type': 'out_invoice', 'partner_id': partner.id, 'invoice_date': fields.Date.context_today(self),
            'ref': w.name, 'invoice_origin': w.name, 'invoice_line_ids': lines,
        })
        move.action_post()
        w.invoice_id = move.id
        if w.payment_mode in ('cash', 'mpesa_code', 'mpesa_stk'):
            journal = w._payment_journal()
            ctx = {'active_model': 'account.move', 'active_ids': move.ids}
            reg = self.env['account.payment.register'].sudo().with_context(**ctx).create({
                'journal_id': journal.id, 'amount': move.amount_total, 'payment_date': fields.Date.context_today(self),
                'communication': f'{w.name} {w.payment_ref or ""}'.strip(),
            })
            reg.action_create_payments()

    def _payment_journal(self):
        self.ensure_one()
        Journal = self.env['account.journal'].sudo()
        if self.payment_mode == 'cash':
            j = self.origin_hub_id.cash_journal_id or Journal.search([('type', '=', 'cash'), ('company_id', '=', self.company_id.id)], limit=1)
        else:
            jid = int(self.env['ir.config_parameter'].sudo().get_param('coastbus.mpesa_journal_id') or 0)
            j = Journal.browse(jid).exists() or Journal.search([('type', '=', 'bank'), ('company_id', '=', self.company_id.id)], limit=1)
        if not j:
            raise UserError(_('No payment journal found for %s.') % self.payment_mode)
        return j

    def action_retry_invoice(self):
        self._try_invoice()
        return True

    def action_view_invoice(self):
        self.ensure_one()
        return {'type': 'ir.actions.act_window', 'res_model': 'account.move', 'res_id': self.invoice_id.id, 'view_mode': 'form'}

    # ------------------------------------------------------------------ status changes
    def cancel_from_terminal(self, staff, device, reason, uuid):
        for w in self.sudo():
            if w.state != 'booked':
                raise UserError(_('%s can only be cancelled before loading (now: %s).') % (w.name, dict(STATES)[w.state]))
            w.state = 'cancelled'
            w._log_scan('cancel', hub=w.current_hub_id, staff=staff, device=device, uuid=uuid, note=reason)
            if w.invoice_id and w.invoice_id.state == 'posted':
                try:
                    with self.env.cr.savepoint():
                        w.invoice_id._reverse_moves([{'ref': _('Cancelled %s: %s') % (w.name, reason)}], cancel=w.invoice_id.payment_state == 'not_paid')
                except Exception as e:
                    w.invoice_error = _('Credit note failed: %s') % str(e)[:200]
            w.message_post(body=_('Cancelled on terminal by %s: %s') % (staff.name, reason))

    def collect_from_terminal(self, d, staff, device):
        for w in self.sudo():
            if w.state == 'collected':
                return
            if w.state not in ('arrived', 'at_hub', 'in_transit'):
                raise UserError(_('%s is not ready for collection (%s).') % (w.name, dict(STATES)[w.state]))
            w.write({'state': 'collected', 'collected_at': d.get('at') or fields.Datetime.now(), 'collected_by_name': d.get('collector_name'),
                     'collected_id_no': d.get('collector_id_no'), 'collected_staff_id': staff.id, 'collect_method': d.get('method') or 'otp',
                     'custodian_id': False, 'current_hub_id': device.hub_id.id})
            if w.payment_mode == 'receiver' and d.get('payment_mode'):
                w.write({'payment_mode': d['payment_mode'], 'payment_ref': (d.get('payment_ref') or '').upper(), 'paid': True})
                w._try_invoice()
            w._log_scan('collect', hub=device.hub_id, staff=staff, device=device, at=d.get('at'), uuid=d['uuid'],
                        note=f"{d.get('collector_name')} ID {d.get('collector_id_no') or '-'} ({d.get('method')})")
            w._queue_sms('collected_sender')

    def _mark_arrived(self, hub, at=None):
        for w in self:
            if w.destination_hub_id == hub:
                w.write({'state': 'arrived', 'current_hub_id': hub.id, 'arrived_at': at or fields.Datetime.now(), 'custodian_id': False})
                w._queue_sms('arrived_receiver')
            else:
                w.write({'state': 'at_hub', 'current_hub_id': hub.id, 'custodian_id': False})

    # ------------------------------------------------------------------ SMS
    def _otp_for_sms(self):
        self.ensure_one()
        w = self.sudo()
        if not w.otp:
            code = f'{secrets.randbelow(1000000):06d}'
            w.write({'otp': code, 'otp_hash': otp_hash(code, w.name)})
        return w.otp

    def _queue_sms(self, kind):
        Sms = self.env['courier.sms'].sudo()
        for w in self:
            to = w.receiver_phone if kind.endswith('receiver') else w.sender_phone
            body = Sms.render(kind, w)
            if body and to:
                Sms.create({'waybill_id': w.id, 'phone': to, 'body': body, 'kind': kind})

    def action_resend_arrival_sms(self):
        self.filtered(lambda w: w.state == 'arrived')._queue_sms('arrived_receiver')
        return True

    # ------------------------------------------------------------------ for the terminal / tracking page
    def to_terminal(self):
        out = []
        for w in self.sudo():
            out.append({
                'id': w.id, 'name': w.name, 'uuid': w.client_uuid, 'state': w.state, 'tracking_token': w.tracking_token,
                'origin_hub_id': w.origin_hub_id.id, 'destination_hub_id': w.destination_hub_id.id, 'current_hub_id': w.current_hub_id.id or 0,
                'sender_name': w.sender_name, 'sender_phone': w.sender_phone, 'receiver_name': w.receiver_name, 'receiver_phone': w.receiver_phone,
                'description': w.description, 'pieces': w.pieces, 'weight': w.weight, 'chargeable_weight': w.chargeable_weight,
                'declared_value': w.declared_value, 'insured': w.insured, 'fragile': w.fragile, 'total': w.total, 'fare': w.fare, 'insurance': w.insurance,
                'payment_mode': w.payment_mode, 'payment_ref': w.payment_ref or '', 'paid': w.paid,
                'booked_at': fields.Datetime.to_string(w.booked_at) if w.booked_at else '', 'booked_by': w.booked_by_id.name or '',
                'manifest_no': w.manifest_id.name or '', 'vehicle': w.vehicle_id.name or '', 'custodian': w.custodian_id.name or '',
                'arrived_at': fields.Datetime.to_string(w.arrived_at) if w.arrived_at else '',
                'collected_at': fields.Datetime.to_string(w.collected_at) if w.collected_at else '',
                'collected_by_name': w.collected_by_name or '', 'otp_hash': w.otp_hash or '',
            })
        return out

    def public_status(self):
        self.ensure_one()
        w = self.sudo()
        steps = []
        for s in w.scan_ids.sorted('scanned_at'):
            if s.kind in ('book', 'depart', 'offload', 'collect', 'cancel') or (s.kind == 'load' and s.piece <= 1):
                steps.append({'at': s.scanned_at, 'text': s.public_text()})
        return {'name': w.name, 'state': dict(STATES)[w.state], 'state_key': w.state, 'from': w.origin_hub_id.name, 'to': w.destination_hub_id.name,
                'receiver': mask_name(w.receiver_name), 'pieces': w.pieces, 'steps': steps}
