from odoo import _, api, fields, models
from odoo.exceptions import UserError


def _pieces(text):
    return {int(x) for x in (text or '').split(',') if x.strip().isdigit()}


def _text(pieces):
    return ','.join(str(x) for x in sorted(pieces))


class CourierManifest(models.Model):
    _name = 'courier.manifest'
    _description = 'Trip Manifest'
    _inherit = ['mail.thread', 'mail.activity.mixin']
    _order = 'id desc'

    name = fields.Char('Manifest no.', required=True, copy=False, index=True)
    client_uuid = fields.Char(copy=False, index=True)
    origin_hub_id = fields.Many2one('courier.hub', 'From', required=True)
    destination_hub_id = fields.Many2one('courier.hub', 'Final stop', required=True, tracking=True)
    vehicle_id = fields.Many2one('courier.vehicle', required=True, tracking=True)
    driver_id = fields.Many2one('courier.staff', 'Driver / custodian', required=True, tracking=True)
    dispatcher_id = fields.Many2one('courier.staff', 'Loaded by')
    receiver_staff_id = fields.Many2one('courier.staff', 'Received by (final stop)')
    supervisor_id = fields.Many2one('courier.staff', 'Supervisor (shortage sign-off)')
    driver_ack = fields.Boolean('Driver acknowledged shortage (PIN)')
    state = fields.Selection([
        ('loading', 'Loading'),
        ('in_transit', 'In transit'),
        ('reconciled', 'Received – all present'),
        ('discrepancy', 'Received – shortage'),
        ('cancelled', 'Cancelled'),
    ], default='loading', required=True, tracking=True, index=True)
    opened_at = fields.Datetime(default=fields.Datetime.now)
    departure_time = fields.Datetime(tracking=True)
    arrival_time = fields.Datetime(tracking=True)
    line_ids = fields.One2many('courier.manifest.line', 'manifest_id', 'Parcels')
    device_id = fields.Many2one('courier.device', 'Terminal')
    total_waybills = fields.Integer('Waybills', compute='_compute_totals', store=True)
    total_pieces = fields.Integer('Pieces loaded', compute='_compute_totals', store=True)
    received_pieces = fields.Integer('Pieces received', compute='_compute_totals', store=True)
    missing_pieces = fields.Integer('Pieces missing', compute='_compute_totals', store=True)
    total_weight = fields.Float('Weight (kg)', compute='_compute_totals', store=True)
    total_value = fields.Float('Declared value', compute='_compute_totals', store=True)
    discrepancy_ids = fields.One2many('courier.discrepancy', 'manifest_id')
    note = fields.Text()

    _sql_constraints = [('name_uniq', 'unique(name)', 'Manifest number already exists.'),
                        ('uuid_uniq', 'unique(client_uuid)', 'Duplicate terminal record.')]

    @api.depends('line_ids.loaded_count', 'line_ids.received_count', 'line_ids.waybill_id.weight', 'line_ids.extra', 'state')
    def _compute_totals(self):
        for m in self:
            lines = m.line_ids.filtered(lambda l: not l.extra)
            m.total_waybills = len(lines)
            m.total_pieces = sum(lines.mapped('loaded_count'))
            m.received_pieces = sum(m.line_ids.mapped('received_count'))
            m.missing_pieces = sum(l.loaded_count - min(l.received_count, l.loaded_count) for l in lines) if m.state in ('reconciled', 'discrepancy') else 0
            m.total_weight = sum(lines.mapped('waybill_id.weight'))
            m.total_value = sum(lines.mapped('waybill_id.declared_value'))

    # ------------------------------------------------------------------ terminal events
    @api.model
    def open_from_terminal(self, d, device, staff):
        m = self.sudo().search(['|', ('client_uuid', '=', d['uuid']), ('name', '=', d['name'])], limit=1)
        if m:
            return m
        Hub = self.env['courier.hub'].sudo()
        dest = Hub.browse(int(d['destination_hub_id'])).exists()
        veh = self.env['courier.vehicle'].sudo().browse(int(d['vehicle_id'])).exists()
        drv = self.env['courier.staff'].sudo().browse(int(d['driver_id'])).exists()
        if not (dest and veh and drv):
            raise UserError(_('Manifest needs destination, vehicle and driver.'))
        return self.sudo().create({'name': d['name'], 'client_uuid': d['uuid'], 'origin_hub_id': device.hub_id.id,
                                   'destination_hub_id': dest.id, 'vehicle_id': veh.id, 'driver_id': drv.id, 'dispatcher_id': staff.id,
                                   'device_id': device.id, 'opened_at': d.get('at') or fields.Datetime.now()})

    def _line(self, w, create=True, extra=False):
        line = self.line_ids.filtered(lambda l: l.waybill_id == w)[:1]
        if not line and create:
            line = self.env['courier.manifest.line'].sudo().create({'manifest_id': self.id, 'waybill_id': w.id, 'extra': extra})
        return line

    def load_piece(self, w, piece, staff, device, at, uuid):
        self.ensure_one()
        if self.state not in ('loading', 'in_transit'):
            raise UserError(_('Manifest %s is closed.') % self.name)
        if w.state in ('collected', 'cancelled'):
            raise UserError(_('%s is %s and cannot be loaded.') % (w.name, w.state))
        if w.manifest_id and w.manifest_id != self and w.manifest_id.state in ('loading', 'in_transit') and w.state != 'at_hub':
            raise UserError(_('%s is already on manifest %s.') % (w.name, w.manifest_id.name))
        line = self._line(w)
        got = _pieces(line.loaded_pieces)
        got.add(max(1, piece))
        line.loaded_pieces = _text(got)
        line.loaded_at = line.loaded_at or at
        vals = {'manifest_id': self.id, 'vehicle_id': self.vehicle_id.id}
        if self.state == 'in_transit':
            vals.update(state='in_transit', custodian_id=self.driver_id.id)
        elif w.state in ('booked', 'at_hub', 'lost'):
            vals['state'] = 'loaded'
        w.write(vals)
        w._log_scan('load', hub=device.hub_id, staff=staff, device=device, at=at, uuid=uuid, piece=piece, manifest=self)

    def unload_piece(self, w, piece, staff, device, at, uuid):
        """Taken off again before departure (wrong vehicle)."""
        self.ensure_one()
        if self.state != 'loading':
            raise UserError(_('Manifest %s has left; record it at the destination instead.') % self.name)
        line = self._line(w, create=False)
        if not line:
            return
        got = _pieces(line.loaded_pieces)
        got.discard(max(1, piece))
        if got:
            line.loaded_pieces = _text(got)
        else:
            line.unlink()
            w.write({'manifest_id': False, 'vehicle_id': False, 'state': 'booked' if w.current_hub_id == w.origin_hub_id else 'at_hub'})
        w._log_scan('unload', hub=device.hub_id, staff=staff, device=device, at=at, uuid=uuid, piece=piece, manifest=self)

    def depart(self, staff, device, at):
        for m in self.sudo():
            if m.state != 'loading':
                continue
            if not m.line_ids:
                raise UserError(_('Cannot dispatch an empty manifest. Scan parcels first.'))
            m.write({'state': 'in_transit', 'departure_time': at or fields.Datetime.now()})
            for line in m.line_ids:
                line.waybill_id.write({'state': 'in_transit', 'custodian_id': m.driver_id.id, 'vehicle_id': m.vehicle_id.id, 'manifest_id': m.id})
                line.waybill_id._log_scan('depart', hub=m.origin_hub_id, staff=staff, device=device, at=at,
                                          uuid=f'{m.client_uuid or m.name}:depart:{line.waybill_id.id}', manifest=m,
                                          note=f'{m.vehicle_id.name} · {m.driver_id.name}')
            m.message_post(body=_('Departed with %s waybills (%s pieces). Driver %s, vehicle %s.') % (
                m.total_waybills, m.total_pieces, m.driver_id.name, m.vehicle_id.name))

    def offload_piece(self, w, piece, staff, device, at, uuid):
        self.ensure_one()
        line = self._line(w, create=False)
        result = 'ok'
        if not line:
            line = self._line(w, extra=True)
            result = 'unexpected'
        got = _pieces(line.received_pieces)
        got.add(max(1, piece))
        line.write({'received_pieces': _text(got), 'received_at': at, 'received_hub_id': device.hub_id.id})
        w._log_scan('offload', hub=device.hub_id, staff=staff, device=device, at=at, uuid=uuid, piece=piece, manifest=self, result=result)

    def expected_lines(self, hub):
        """Parcels this branch must take off the vehicle: those addressed here, or everything still on board at the final stop."""
        self.ensure_one()
        lines = self.line_ids.filtered(lambda l: not l.extra)
        if hub == self.destination_hub_id:
            return lines.filtered(lambda l: not l.received_hub_id or l.received_hub_id == hub)
        return lines.filtered(lambda l: l.waybill_id.destination_hub_id == hub)

    def receive_complete(self, d, staff, device):
        """Offloading finished at this branch: tally loaded vs offloaded, flag shortages."""
        self.ensure_one()
        hub = device.hub_id
        at = d.get('at') or fields.Datetime.now()
        Staff = self.env['courier.staff'].sudo()
        sup = Staff.browse(int(d.get('supervisor_id') or 0)).exists()
        final = hub == self.destination_hub_id
        short = []
        for line in self.expected_lines(hub):
            loaded, received = _pieces(line.loaded_pieces), _pieces(line.received_pieces)
            missing = loaded - received
            if missing:
                short.append((line, missing))
            else:
                line.waybill_id._mark_arrived(hub, at)
                line.state = 'ok'
        # extras (on this vehicle but never loaded on this manifest) still arrive here
        for line in self.line_ids.filtered(lambda l: l.extra and l.received_hub_id == hub and l.state == 'open'):
            line.waybill_id._mark_arrived(hub, at)
            line.state = 'extra'
            self.env['courier.discrepancy'].sudo().create({
                'kind': 'excess', 'manifest_id': self.id, 'waybill_id': line.waybill_id.id, 'station_hub_id': hub.id,
                'responsible_driver_id': self.driver_id.id, 'vehicle_id': self.vehicle_id.id, 'liability': 'origin',
                'missing_pieces': '', 'declared_value': line.waybill_id.declared_value,
                'investigation_notes': _('Offloaded from %s but never scanned onto it at loading.') % self.vehicle_id.name})
        for line, missing in short:
            w = line.waybill_id
            loaded_scan = w.scan_ids.filtered(lambda s: s.kind == 'load' and s.manifest_id == self)[:1]
            if len(missing) == len(_pieces(line.loaded_pieces)):
                w.write({'state': 'lost', 'custodian_id': self.driver_id.id})
            else:
                w._mark_arrived(hub, at)
            line.state = 'short'
            self.env['courier.discrepancy'].sudo().create({
                'kind': 'shortage', 'manifest_id': self.id, 'waybill_id': w.id, 'station_hub_id': hub.id,
                'responsible_driver_id': self.driver_id.id, 'vehicle_id': self.vehicle_id.id,
                'liability': 'driver' if loaded_scan else 'origin', 'missing_pieces': _text(missing),
                'loaded_scan_at': loaded_scan.scanned_at if loaded_scan else False, 'loaded_by_id': loaded_scan.staff_id.id if loaded_scan else False,
                'declared_value': w.declared_value, 'driver_ack': bool(d.get('driver_ack')), 'supervisor_id': sup.id or False,
                'investigation_notes': d.get('note') or ''})
        if final:
            vals = {'arrival_time': at, 'receiver_staff_id': staff.id, 'supervisor_id': sup.id or False, 'driver_ack': bool(d.get('driver_ack')),
                    'state': 'discrepancy' if (short or self.discrepancy_ids.filtered(lambda x: x.kind == 'shortage')) else 'reconciled'}
            self.write(vals)
        self.message_post(body=_('Offloading at %s by %s: %s shortage(s).') % (hub.name, staff.name, len(short)))
        return short

    def to_terminal(self):
        out = []
        for m in self.sudo():
            out.append({
                'id': m.id, 'name': m.name, 'uuid': m.client_uuid, 'state': m.state,
                'origin_hub_id': m.origin_hub_id.id, 'destination_hub_id': m.destination_hub_id.id,
                'vehicle_id': m.vehicle_id.id, 'vehicle': m.vehicle_id.name, 'driver_id': m.driver_id.id, 'driver': m.driver_id.name,
                'departure_time': fields.Datetime.to_string(m.departure_time) if m.departure_time else '',
                'lines': [{'waybill_id': l.waybill_id.id, 'name': l.waybill_id.name, 'pieces': l.waybill_id.pieces,
                           'destination_hub_id': l.waybill_id.destination_hub_id.id, 'loaded': l.loaded_pieces or '',
                           'received': l.received_pieces or '', 'received_hub_id': l.received_hub_id.id or 0, 'extra': l.extra,
                           'weight': l.waybill_id.weight, 'description': l.waybill_id.description,
                           'loaded_at': fields.Datetime.to_string(l.loaded_at) if l.loaded_at else ''} for l in m.line_ids],
            })
        return out


class CourierManifestLine(models.Model):
    _name = 'courier.manifest.line'
    _description = 'Manifest Parcel'
    _order = 'id'

    manifest_id = fields.Many2one('courier.manifest', required=True, ondelete='cascade', index=True)
    waybill_id = fields.Many2one('courier.waybill', required=True, index=True)
    destination_hub_id = fields.Many2one(related='waybill_id.destination_hub_id', store=True)
    pieces = fields.Integer(related='waybill_id.pieces')
    loaded_pieces = fields.Char('Pieces loaded')
    received_pieces = fields.Char('Pieces offloaded')
    loaded_count = fields.Integer(compute='_compute_counts', store=True)
    received_count = fields.Integer(compute='_compute_counts', store=True)
    loaded_at = fields.Datetime()
    received_at = fields.Datetime()
    received_hub_id = fields.Many2one('courier.hub', 'Offloaded at')
    extra = fields.Boolean('Not loaded on this manifest', help='Offloaded but never scanned at loading')
    state = fields.Selection([('open', 'On board'), ('ok', 'Offloaded'), ('short', 'Missing'), ('extra', 'Unexpected')], default='open')

    @api.depends('loaded_pieces', 'received_pieces')
    def _compute_counts(self):
        for l in self:
            l.loaded_count = len(_pieces(l.loaded_pieces))
            l.received_count = len(_pieces(l.received_pieces))
