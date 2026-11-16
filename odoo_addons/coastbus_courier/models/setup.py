import secrets

from odoo import _, api, fields, models
from odoo.exceptions import UserError, ValidationError

from .common import hash_pin, new_salt, norm_phone

CFG_KEYS = {
    # key: (type, default)
    'vol_divisor': (float, 5000.0),
    'insurance_pct': (float, 1.0),
    'insurance_min': (float, 0.0),
    'vat_pct': (float, 16.0),
    'receipt_footer': (str, 'Parcels not collected within 30 days attract storage charges.'),
    'terms': (str, 'Liability is limited to the declared value for insured parcels.'),
    'track_url': (str, ''),
    'sms_provider': (str, 'none'),
    'sms_sender_notice': (bool, True),
    'sms_receiver_notice': (bool, True),
    'pay_cash': (bool, True),
    'pay_mpesa_code': (bool, True),
    'pay_mpesa_stk': (bool, False),
    'pay_account': (bool, True),
    'collect_needs_otp': (bool, True),
    'storage_days': (float, 30.0),
    'wb_prefix': (str, 'CB'),
    'idle_lock_minutes': (float, 10.0),
}


class CourierConfig(models.AbstractModel):
    _name = 'courier.config'
    _description = 'Courier settings helper'

    @api.model
    def get_cfg(self):
        icp = self.env['ir.config_parameter'].sudo()
        out = {}
        for k, (typ, default) in CFG_KEYS.items():
            raw = icp.get_param('coastbus.' + k)
            if raw in (None, False, ''):
                # Odoo deletes a boolean setting when it is unticked: missing = off (defaults are written at install)
                out[k] = False if typ is bool else default
            elif typ is bool:
                out[k] = raw in ('1', 'True', 'true')
            elif typ is float:
                try:
                    out[k] = float(raw)
                except ValueError:
                    out[k] = default
            else:
                out[k] = raw
        if not out['track_url']:
            out['track_url'] = (icp.get_param('web.base.url') or '').rstrip('/') + '/t/'
        return out


class CourierHub(models.Model):
    _name = 'courier.hub'
    _description = 'Courier Branch'
    _order = 'sequence, name'

    name = fields.Char('Branch', required=True)
    code = fields.Char('Code', required=True, size=5, help='Short code printed on waybills, e.g. MSA, NBO, VOI')
    sequence = fields.Integer(default=10)
    phone = fields.Char()
    address = fields.Char()
    active = fields.Boolean(default=True)
    company_id = fields.Many2one('res.company', default=lambda s: s.env.company, required=True)
    cash_journal_id = fields.Many2one('account.journal', 'Cash journal', domain="[('type', 'in', ('cash', 'bank'))]",
                                      help='Cash taken at this branch is posted here. Empty = the company cash journal.')
    waybill_count = fields.Integer(compute='_compute_counts')

    _sql_constraints = [('code_uniq', 'unique(code)', 'Branch codes must be unique.')]

    @api.constrains('code')
    def _check_code(self):
        for h in self:
            if not (h.code or '').isalnum():
                raise ValidationError(_('Branch code must be letters/numbers only (e.g. MSA).'))

    @api.model_create_multi
    def create(self, vals_list):
        for v in vals_list:
            if v.get('code'):
                v['code'] = v['code'].upper().strip()
        return super().create(vals_list)

    def write(self, vals):
        if vals.get('code'):
            vals['code'] = vals['code'].upper().strip()
        return super().write(vals)

    def _compute_counts(self):
        data = self.env['courier.waybill']._read_group([('origin_hub_id', 'in', self.ids)], ['origin_hub_id'], ['__count'])
        m = {h.id: c for h, c in data}
        for h in self:
            h.waybill_count = m.get(h.id, 0)


class CourierRoute(models.Model):
    _name = 'courier.route'
    _description = 'Courier Route & Tariff'
    _order = 'origin_hub_id, destination_hub_id'

    name = fields.Char(compute='_compute_name', store=True)
    origin_hub_id = fields.Many2one('courier.hub', 'From', required=True)
    destination_hub_id = fields.Many2one('courier.hub', 'To', required=True)
    base_fare = fields.Float('Base fare', required=True, default=300, help='Charge covering the first "Base kg"')
    base_kg = fields.Float('Base kg', default=2)
    rate_per_kg = fields.Float('Each extra kg', default=50)
    extra_piece_fee = fields.Float('Each extra piece', default=0)
    min_charge = fields.Float('Minimum charge', default=200)
    transit_hours = fields.Float('Usual transit (hours)', default=10)
    active = fields.Boolean(default=True)
    both_ways = fields.Boolean('Same tariff both ways', default=True,
                               help='When ticked, this tariff also applies for the opposite direction if no tariff exists for it.')

    _sql_constraints = [('pair_uniq', 'unique(origin_hub_id, destination_hub_id)', 'There is already a tariff for this route.')]

    @api.depends('origin_hub_id', 'destination_hub_id')
    def _compute_name(self):
        for r in self:
            r.name = f'{r.origin_hub_id.code or "?"} → {r.destination_hub_id.code or "?"}'

    @api.constrains('origin_hub_id', 'destination_hub_id')
    def _check_pair(self):
        for r in self:
            if r.origin_hub_id == r.destination_hub_id:
                raise ValidationError(_('Origin and destination must differ.'))

    @api.model
    def find(self, origin, dest):
        r = self.search([('origin_hub_id', '=', origin.id), ('destination_hub_id', '=', dest.id)], limit=1)
        if not r:
            r = self.search([('origin_hub_id', '=', dest.id), ('destination_hub_id', '=', origin.id), ('both_ways', '=', True)], limit=1)
        return r


class CourierVehicle(models.Model):
    _name = 'courier.vehicle'
    _description = 'Vehicle'
    _order = 'name'

    name = fields.Char('Plate number', required=True)
    description = fields.Char('Vehicle', help='e.g. Scania bus 67 seater, Isuzu 5-ton')
    capacity_kg = fields.Float('Parcel capacity (kg)')
    active = fields.Boolean(default=True)

    _sql_constraints = [('plate_uniq', 'unique(name)', 'This plate number already exists.')]

    @api.model_create_multi
    def create(self, vals_list):
        for v in vals_list:
            v['name'] = (v.get('name') or '').upper().strip()
        return super().create(vals_list)


class CourierStaff(models.Model):
    _name = 'courier.staff'
    _description = 'Courier Staff (handheld users)'
    _order = 'name'

    name = fields.Char(required=True)
    code = fields.Char('Staff no.', help='e.g. DRV-014')
    phone = fields.Char()
    id_number = fields.Char('ID number')
    role = fields.Selection([
        ('clerk', 'Office clerk (intake & billing)'),
        ('loader', 'Loader / Driver (loading & offloading scans)'),
        ('supervisor', 'Supervisor (all + approvals)'),
    ], required=True, default='clerk')
    hub_id = fields.Many2one('courier.hub', 'Branch', help='Empty = can work at any branch (e.g. drivers)')
    pin_hash = fields.Char(copy=False, groups='coastbus_courier.group_courier_manager')
    pin_salt = fields.Char(copy=False, groups='coastbus_courier.group_courier_manager')
    has_pin = fields.Boolean(compute='_compute_has_pin')
    new_pin = fields.Char('Set PIN', store=False, help='4 to 6 digits. Leave empty to keep the current PIN.')
    partner_id = fields.Many2one('res.partner', 'Contact (for liability entries)')
    active = fields.Boolean(default=True)

    def _compute_has_pin(self):
        for s in self.sudo():
            s.has_pin = bool(s.pin_hash)

    def _apply_pin(self, pin):
        pin = (pin or '').strip()
        if not pin.isdigit() or not 4 <= len(pin) <= 6:
            raise UserError(_('The PIN must be 4 to 6 digits.'))
        salt = new_salt()
        self.sudo().write({'pin_salt': salt, 'pin_hash': hash_pin(pin, salt)})

    @api.model_create_multi
    def create(self, vals_list):
        pins = [v.pop('new_pin', None) for v in vals_list]
        recs = super().create(vals_list)
        for r, p in zip(recs, pins):
            if p:
                r._apply_pin(p)
        return recs

    def write(self, vals):
        pin = vals.pop('new_pin', None)
        if vals.get('phone'):
            vals['phone'] = norm_phone(vals['phone'])
        res = super().write(vals)
        if pin:
            for r in self:
                r._apply_pin(pin)
        return res


class CourierDevice(models.Model):
    _name = 'courier.device'
    _description = 'Handheld Terminal'
    _order = 'number'

    name = fields.Char(required=True, default=lambda s: _('Terminal'))
    number = fields.Integer('Terminal no.', readonly=True, copy=False,
                            help='Printed inside waybill numbers made on this terminal, e.g. CB-MSA-07-00012')
    hub_id = fields.Many2one('courier.hub', 'Branch', required=True)
    activation_key = fields.Char(readonly=True, copy=False)
    token_hash = fields.Char(copy=False, groups='base.group_system')
    device_uid = fields.Char('Hardware id', readonly=True, copy=False)
    model_name = fields.Char('Model', readonly=True)
    app_version = fields.Char(readonly=True)
    last_seen = fields.Datetime(readonly=True)
    activated = fields.Boolean(readonly=True, copy=False)
    active = fields.Boolean(default=True)
    state_text = fields.Char(compute='_compute_state_text')

    _sql_constraints = [('num_uniq', 'unique(number)', 'Terminal number already used.')]

    @api.model_create_multi
    def create(self, vals_list):
        self.flush_model(['number'])
        self.env.cr.execute('SELECT COALESCE(MAX(number), 0) FROM courier_device')
        nxt = self.env.cr.fetchone()[0]
        for v in vals_list:
            nxt += 1
            v['number'] = nxt
            v['activation_key'] = self._new_key()
        return super().create(vals_list)

    @staticmethod
    def _new_key():
        alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        return ''.join(secrets.choice(alphabet) for _ in range(8))

    def _compute_state_text(self):
        for d in self:
            d.state_text = _('Active') if d.activated else _('Waiting: type the key on the terminal')

    def action_new_key(self):
        """Re-activate (new phone, or the old one was lost): the old terminal stops working."""
        for d in self:
            d.sudo().write({'activation_key': self._new_key(), 'activated': False, 'token_hash': False, 'device_uid': False})
        return True
