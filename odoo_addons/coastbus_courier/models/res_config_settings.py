from odoo import _, fields, models
from odoo.exceptions import UserError

from .sms import TEMPLATES


class ResPartner(models.Model):
    _inherit = 'res.partner'

    courier_account = fields.Boolean('Courier account customer', help='Can book parcels on credit (billed on invoice) from the handhelds.')


class ResConfigSettings(models.TransientModel):
    _inherit = 'res.config.settings'

    cb_vol_divisor = fields.Float('Volumetric divisor', config_parameter='coastbus.vol_divisor', default=5000,
                                  help='Volumetric kg = L x W x H (cm) / divisor')
    cb_insurance_pct = fields.Float('Insurance %', config_parameter='coastbus.insurance_pct', default=1.0)
    cb_insurance_min = fields.Float('Minimum insurance', config_parameter='coastbus.insurance_min')
    cb_vat_pct = fields.Float('VAT % (included in prices)', config_parameter='coastbus.vat_pct', default=16.0,
                              help='Only for the "VAT included" line on receipts. Set 0 if not VAT registered.')
    cb_receipt_footer = fields.Char('Receipt footer', config_parameter='coastbus.receipt_footer')
    cb_terms = fields.Char('Terms on receipt', config_parameter='coastbus.terms')
    cb_track_url = fields.Char('Tracking link base', config_parameter='coastbus.track_url',
                               help='Empty = this Odoo address + /t/ (e.g. https://courier.coastbus.co.ke/t/)')
    cb_wb_prefix = fields.Char('Waybill prefix', config_parameter='coastbus.wb_prefix', default='CB',
                               help='Waybill numbers: PREFIX-BRANCH-TERMINAL-NUMBER, e.g. CB-MSA-07-00012')
    cb_idle_lock_minutes = fields.Integer('Lock terminal after (minutes idle)', config_parameter='coastbus.idle_lock_minutes', default=10)
    cb_storage_days = fields.Integer('Free storage days', config_parameter='coastbus.storage_days', default=30)
    cb_collect_needs_otp = fields.Boolean('Collection needs the SMS code', config_parameter='coastbus.collect_needs_otp', default=True,
                                          help='Without the code, the receiver ID and a supervisor PIN are needed.')
    cb_pay_cash = fields.Boolean('Cash', config_parameter='coastbus.pay_cash', default=True)
    cb_pay_mpesa_code = fields.Boolean('M-Pesa code typed in', config_parameter='coastbus.pay_mpesa_code', default=True)
    cb_pay_mpesa_stk = fields.Boolean('M-Pesa STK push', config_parameter='coastbus.pay_mpesa_stk')
    cb_pay_account = fields.Boolean('Account customers (credit)', config_parameter='coastbus.pay_account', default=True)
    cb_tax_id = fields.Many2one('account.tax', 'VAT on invoices (price included)', config_parameter='coastbus.tax_id',
                                domain="[('type_tax_use', '=', 'sale'), ('price_include', '=', True)]",
                                help='Terminal prices include VAT. Choose a sales tax with "Included in price" ticked, or leave empty (no VAT).')
    cb_mpesa_journal_id = fields.Many2one('account.journal', 'M-Pesa journal', config_parameter='coastbus.mpesa_journal_id',
                                          domain="[('type', 'in', ('bank', 'cash'))]")
    cb_mpesa_env = fields.Selection([('sandbox', 'Sandbox (testing)'), ('production', 'Live')], 'Daraja', config_parameter='coastbus.mpesa_env', default='sandbox')
    cb_mpesa_type = fields.Selection([('paybill', 'Paybill'), ('till', 'Till (Buy Goods)')], 'Collect on', config_parameter='coastbus.mpesa_type', default='paybill')
    cb_mpesa_shortcode = fields.Char('Shortcode (paybill / store no.)', config_parameter='coastbus.mpesa_shortcode')
    cb_mpesa_till = fields.Char('Till number', config_parameter='coastbus.mpesa_till')
    cb_mpesa_consumer_key = fields.Char('Consumer key', config_parameter='coastbus.mpesa_consumer_key')
    cb_mpesa_consumer_secret = fields.Char('Consumer secret', config_parameter='coastbus.mpesa_consumer_secret')
    cb_mpesa_passkey = fields.Char('Passkey', config_parameter='coastbus.mpesa_passkey')
    cb_mpesa_callback_url = fields.Char('Callback URL', config_parameter='coastbus.mpesa_callback_url',
                                        help='Empty = this Odoo address + /courier/mpesa/callback (must be https and public)')
    cb_sms_provider = fields.Selection([('none', 'Not set yet (SMS wait in the queue)'), ('africastalking', "Africa's Talking"),
                                        ('http', 'Other provider (HTTP API)')], 'SMS provider', config_parameter='coastbus.sms_provider', default='none')
    cb_sms_sender_notice = fields.Boolean('SMS to sender on booking', config_parameter='coastbus.sms_sender_notice', default=True)
    cb_sms_receiver_notice = fields.Boolean('SMS to receiver on booking', config_parameter='coastbus.sms_receiver_notice', default=True)
    cb_at_username = fields.Char("Africa's Talking username", config_parameter='coastbus.at_username')
    cb_at_api_key = fields.Char('API key', config_parameter='coastbus.at_api_key')
    cb_at_sender_id = fields.Char('Sender ID', config_parameter='coastbus.at_sender_id')
    cb_http_url = fields.Char('API URL', config_parameter='coastbus.http_url', help='May contain {phone} {message} {sender}')
    cb_http_method = fields.Selection([('POST', 'POST'), ('GET', 'GET')], 'Method', config_parameter='coastbus.http_method', default='POST')
    cb_http_headers = fields.Char('Headers (JSON)', config_parameter='coastbus.http_headers', help='e.g. {"Content-Type": "application/json", "apikey": "..."}')
    cb_http_body = fields.Char('Body', config_parameter='coastbus.http_body',
                               help='Placeholders: {phone} (+2547...), {phone_local} (07...), {phone_plain} (2547...), {message}, {sender}')
    cb_http_sender = fields.Char('Sender ID ', config_parameter='coastbus.http_sender')
    cb_sms_tpl_booked_sender = fields.Char('Booking (to sender)', config_parameter='coastbus.sms_tpl_booked_sender', default=TEMPLATES['booked_sender'])
    cb_sms_tpl_booked_receiver = fields.Char('Booking (to receiver)', config_parameter='coastbus.sms_tpl_booked_receiver', default=TEMPLATES['booked_receiver'])
    cb_sms_tpl_arrived_receiver = fields.Char('Arrival (to receiver)', config_parameter='coastbus.sms_tpl_arrived_receiver', default=TEMPLATES['arrived_receiver'])
    cb_sms_tpl_collected_sender = fields.Char('Collected (to sender)', config_parameter='coastbus.sms_tpl_collected_sender', default=TEMPLATES['collected_sender'])
    cb_sms_test_phone = fields.Char('Test phone')
    cb_driver_receivable_account_id = fields.Many2one('account.account', 'Driver liability account', config_parameter='coastbus.driver_receivable_account_id')
    cb_claims_account_id = fields.Many2one('account.account', 'Claims payable account', config_parameter='coastbus.claims_account_id')

    def action_cb_test_sms(self):
        self.ensure_one()
        if not self.cb_sms_test_phone:
            raise UserError(_('Enter the test phone number first.'))
        self.execute()
        from .common import norm_phone
        sms = self.env['courier.sms'].sudo().action_send_test(norm_phone(self.cb_sms_test_phone))
        msg = _('Test SMS sent.') if sms.state == 'sent' else _('Test SMS failed: %s') % (sms.error or sms.state)
        return {'type': 'ir.actions.client', 'tag': 'display_notification',
                'params': {'message': msg, 'type': 'success' if sms.state == 'sent' else 'danger', 'sticky': sms.state != 'sent'}}
