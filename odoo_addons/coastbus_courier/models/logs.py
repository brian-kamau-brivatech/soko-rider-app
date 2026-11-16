from odoo import _, fields, models
from odoo.exceptions import UserError

SCAN_KINDS = [
    ('book', 'Booked'),
    ('load', 'Loaded'),
    ('unload', 'Taken off before departure'),
    ('depart', 'Departed'),
    ('offload', 'Offloaded'),
    ('collect', 'Collected'),
    ('recover', 'Recovered'),
    ('cancel', 'Cancelled'),
    ('note', 'Note'),
]


class CourierScan(models.Model):
    """Custody log: one row per scan or hand-over. Never edited."""
    _name = 'courier.scan'
    _description = 'Custody Scan'
    _order = 'scanned_at desc, id desc'

    waybill_id = fields.Many2one('courier.waybill', required=True, ondelete='cascade', index=True)
    kind = fields.Selection(SCAN_KINDS, required=True)
    piece = fields.Integer()
    hub_id = fields.Many2one('courier.hub', 'Branch')
    manifest_id = fields.Many2one('courier.manifest', index=True)
    staff_id = fields.Many2one('courier.staff', 'By')
    device_id = fields.Many2one('courier.device', 'Terminal')
    scanned_at = fields.Datetime(required=True, index=True)
    received_at = fields.Datetime('Synced', default=fields.Datetime.now)
    client_uuid = fields.Char(index=True)
    result = fields.Selection([('ok', 'OK'), ('unexpected', 'Not on manifest'), ('duplicate', 'Duplicate'), ('wrong_hub', 'Wrong branch')], default='ok')
    note = fields.Char()

    def write(self, vals):
        if not self.env.su:
            raise UserError(_('The custody log cannot be changed.'))
        return super().write(vals)

    def unlink(self):
        if not self.env.su:
            raise UserError(_('The custody log cannot be deleted.'))
        return super().unlink()

    def public_text(self):
        self.ensure_one()
        hub = self.hub_id.name or ''
        return {
            'book': _('Received at %s') % hub,
            'load': _('Loaded on vehicle at %s') % hub,
            'depart': _('Left %s') % hub,
            'offload': _('Arrived at %s') % hub,
            'collect': _('Collected at %s') % hub,
            'recover': _('Located at %s') % hub,
            'cancel': _('Cancelled'),
        }.get(self.kind, dict(SCAN_KINDS).get(self.kind, ''))


class CourierEvent(models.Model):
    """Every record the terminals send, with its result: makes the sync safe to repeat."""
    _name = 'courier.event'
    _description = 'Terminal Event'
    _order = 'id desc'

    uuid = fields.Char(required=True, index=True)
    kind = fields.Char(required=True)
    device_id = fields.Many2one('courier.device', index=True)
    staff_id = fields.Many2one('courier.staff')
    payload = fields.Text()
    ok = fields.Boolean()
    error = fields.Char()
    tries = fields.Integer(default=1)

    _sql_constraints = [('uuid_uniq', 'unique(uuid)', 'Duplicate event.')]
