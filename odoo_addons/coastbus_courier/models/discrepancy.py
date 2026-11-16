from odoo import _, api, fields, models
from odoo.exceptions import UserError


class CourierDiscrepancy(models.Model):
    _name = 'courier.discrepancy'
    _description = 'Shortage / Loss Investigation'
    _inherit = ['mail.thread', 'mail.activity.mixin']
    _order = 'id desc'

    name = fields.Char('Incident no.', required=True, copy=False, readonly=True, default=lambda s: _('New'))
    kind = fields.Selection([('shortage', 'Shortage (loaded, not offloaded)'), ('excess', 'Unexpected parcel (offloaded, never loaded)')],
                            required=True, default='shortage')
    manifest_id = fields.Many2one('courier.manifest', 'Manifest', readonly=True, index=True)
    waybill_id = fields.Many2one('courier.waybill', 'Waybill', readonly=True, index=True)
    station_hub_id = fields.Many2one('courier.hub', 'Found at', readonly=True)
    origin_hub_id = fields.Many2one(related='waybill_id.origin_hub_id', store=True)
    destination_hub_id = fields.Many2one(related='waybill_id.destination_hub_id', store=True)
    responsible_driver_id = fields.Many2one('courier.staff', 'Last custodian (driver)', readonly=True, tracking=True)
    vehicle_id = fields.Many2one('courier.vehicle', readonly=True)
    liability = fields.Selection([('driver', 'Driver / vehicle (loaded scan exists)'),
                                  ('origin', 'Origin branch (never scanned onto the vehicle)'),
                                  ('none', 'No liability (recovered / explained)')], tracking=True)
    missing_pieces = fields.Char('Missing pieces')
    loaded_scan_at = fields.Datetime('Loading scan', readonly=True)
    loaded_by_id = fields.Many2one('courier.staff', 'Loaded by', readonly=True)
    driver_ack = fields.Boolean('Driver acknowledged (PIN)', readonly=True)
    supervisor_id = fields.Many2one('courier.staff', 'Supervisor', readonly=True)
    currency_id = fields.Many2one('res.currency', default=lambda s: s.env.company.currency_id)
    declared_value = fields.Monetary('Declared value')
    claim_amount = fields.Monetary('Claim / liability amount', tracking=True)
    status = fields.Selection([
        ('open', 'Investigation open'),
        ('vehicle_search', 'Vehicle physical sweep'),
        ('recovered', 'Recovered'),
        ('loss_confirmed', 'Loss confirmed'),
        ('written_off', 'Claim paid / written off'),
    ], default='open', required=True, tracking=True)
    investigation_notes = fields.Text('Findings')
    driver_statement = fields.Text()
    liability_move_id = fields.Many2one('account.move', 'Liability entry', readonly=True)

    @api.model_create_multi
    def create(self, vals_list):
        for v in vals_list:
            if v.get('name', _('New')) == _('New'):
                v['name'] = self.env['ir.sequence'].next_by_code('courier.discrepancy') or _('New')
            if not v.get('claim_amount'):
                w = self.env['courier.waybill'].browse(v.get('waybill_id'))
                v['claim_amount'] = v.get('declared_value') or (w.total if w else 0)
        recs = super().create(vals_list)
        managers = self.env.ref('coastbus_courier.group_courier_manager').users
        for r in recs.filtered(lambda r: r.kind == 'shortage'):
            for u in managers[:5]:
                r.activity_schedule('mail.mail_activity_data_todo', user_id=u.id,
                                    summary=_('Missing parcel %s on %s') % (r.waybill_id.name, r.manifest_id.name))
        return recs

    def action_vehicle_search(self):
        self.write({'status': 'vehicle_search'})

    def action_recovered(self):
        for r in self:
            r.write({'status': 'recovered', 'liability': 'none'})
            w = r.waybill_id
            if w.state == 'lost':
                hub = r.station_hub_id or w.destination_hub_id
                w._mark_arrived(hub)
                w._log_scan('recover', hub=hub, note=_('Recovered (%s)') % r.name)

    def action_confirm_loss(self):
        for r in self:
            r.status = 'loss_confirmed'
            if r.liability == 'driver' and r.claim_amount and not r.liability_move_id:
                r._post_liability()

    def action_written_off(self):
        self.write({'status': 'written_off'})

    def _post_liability(self):
        """Optional: Dr driver (receivable) / Cr claims payable, when both accounts are set in Courier settings."""
        icp = self.env['ir.config_parameter'].sudo()
        dr = self.env['account.account'].browse(int(icp.get_param('coastbus.driver_receivable_account_id') or 0)).exists()
        cr = self.env['account.account'].browse(int(icp.get_param('coastbus.claims_account_id') or 0)).exists()
        journal = self.env['account.journal'].search([('type', '=', 'general'), ('company_id', '=', self.env.company.id)], limit=1)
        if not (dr and cr and journal):
            self.message_post(body=_('Loss confirmed. No liability entry: set the driver and claims accounts in Courier settings.'))
            return
        partner = self.responsible_driver_id.partner_id
        if not partner:
            partner = self.env['res.partner'].sudo().create({'name': self.responsible_driver_id.name, 'phone': self.responsible_driver_id.phone})
            self.responsible_driver_id.partner_id = partner
        label = _('Loss %s · %s · %s') % (self.name, self.waybill_id.name, self.vehicle_id.name or '')
        move = self.env['account.move'].sudo().create({
            'move_type': 'entry', 'journal_id': journal.id, 'ref': label, 'date': fields.Date.context_today(self),
            'line_ids': [(0, 0, {'account_id': dr.id, 'partner_id': partner.id, 'name': label, 'debit': self.claim_amount}),
                         (0, 0, {'account_id': cr.id, 'partner_id': self.waybill_id.sender_partner_id.id, 'name': label, 'credit': self.claim_amount})]})
        move.action_post()
        self.liability_move_id = move.id

    def unlink(self):
        if any(r.status not in ('recovered',) for r in self) and not self.env.su:
            raise UserError(_('Investigations are kept as a record. Mark them recovered or written off instead.'))
        return super().unlink()
