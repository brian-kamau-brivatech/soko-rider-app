import json
import logging

import requests

from odoo import _, api, fields, models

_logger = logging.getLogger(__name__)

TEMPLATES = {
    'booked_sender': 'Coast Bus Courier: parcel {waybill} to {receiver} ({dest}) received at {origin}. Amount KES {total}. Track: {link}',
    'booked_receiver': 'Coast Bus Courier: {sender} has sent you a parcel {waybill} from {origin} to {dest}. Track: {link}',
    'arrived_receiver': 'Coast Bus Courier: your parcel {waybill} from {sender} has arrived at {dest}. Collection code: {otp}. Bring your ID.',
    'collected_sender': 'Coast Bus Courier: parcel {waybill} was collected at {dest} by {collector} on {date}. Thank you.',
}


class CourierSms(models.Model):
    _name = 'courier.sms'
    _description = 'Courier SMS'
    _order = 'id desc'

    waybill_id = fields.Many2one('courier.waybill', index=True, ondelete='set null')
    phone = fields.Char(required=True)
    body = fields.Text(required=True)
    kind = fields.Char()
    state = fields.Selection([('queued', 'Queued'), ('sent', 'Sent'), ('failed', 'Failed'), ('no_provider', 'No SMS provider set')],
                             default='queued', index=True)
    tries = fields.Integer()
    error = fields.Char()
    provider_ref = fields.Char()
    sent_at = fields.Datetime()

    @api.model
    def template(self, kind):
        return self.env['ir.config_parameter'].sudo().get_param('coastbus.sms_tpl_' + kind) or TEMPLATES.get(kind, '')

    @api.model
    def render(self, kind, w):
        tpl = self.template(kind)
        if not tpl:
            return ''
        otp = self.env.context.get('courier_otp') or ''
        if kind == 'arrived_receiver' and not otp:
            otp = w.sudo()._otp_for_sms()
        data = {
            'waybill': w.name, 'sender': w.sender_name, 'receiver': w.receiver_name, 'origin': w.origin_hub_id.name,
            'dest': w.destination_hub_id.name, 'total': f'{w.total:,.0f}', 'link': w.track_link, 'otp': otp or '-',
            'collector': w.collected_by_name or '', 'date': fields.Datetime.context_timestamp(w.with_context(tz=self.env.user.tz or 'Africa/Nairobi'), w.collected_at or fields.Datetime.now()).strftime('%d/%m %H:%M'),
            'pieces': w.pieces,
        }
        try:
            return tpl.format(**data)
        except (KeyError, IndexError, ValueError):
            return TEMPLATES.get(kind, '').format(**data)

    # ------------------------------------------------------------------ sending
    @api.model
    def _cron_send(self, limit=100):
        provider = self.env['ir.config_parameter'].sudo().get_param('coastbus.sms_provider') or 'none'
        queued = self.search([('state', '=', 'queued')], limit=limit, order='id')
        if provider == 'none':
            # kept: they go out once a provider is set (see action_requeue)
            return
        for sms in queued:
            sms._send_one(provider)
            self.env.cr.commit()

    def _send_one(self, provider):
        icp = self.env['ir.config_parameter'].sudo()
        self.tries += 1
        try:
            if provider == 'africastalking':
                user = icp.get_param('coastbus.at_username') or 'sandbox'
                url = 'https://api.sandbox.africastalking.com/version1/messaging' if user == 'sandbox' else 'https://api.africastalking.com/version1/messaging'
                data = {'username': user, 'to': self.phone, 'message': self.body}
                if icp.get_param('coastbus.at_sender_id'):
                    data['from'] = icp.get_param('coastbus.at_sender_id')
                r = requests.post(url, data=data, headers={'apiKey': icp.get_param('coastbus.at_api_key') or '', 'Accept': 'application/json'}, timeout=20)
                r.raise_for_status()
                rec = (r.json().get('SMSMessageData', {}).get('Recipients') or [{}])[0]
                if rec.get('status') not in ('Success', 'Sent', 'Queued') and rec.get('statusCode') not in (100, 101, 102):
                    raise ValueError(rec.get('status') or r.text[:200])
                self.provider_ref = rec.get('messageId')
            elif provider == 'http':
                # any provider with an HTTP API: URL, method, headers (JSON) and body template with {phone} {message} {sender}
                url = icp.get_param('coastbus.http_url') or ''
                method = (icp.get_param('coastbus.http_method') or 'POST').upper()
                headers = json.loads(icp.get_param('coastbus.http_headers') or '{}')
                sender = icp.get_param('coastbus.http_sender') or ''
                fill = {'phone': self.phone, 'phone_local': '0' + self.phone[4:] if self.phone.startswith('+254') else self.phone,
                        'phone_plain': self.phone.lstrip('+'), 'message': self.body, 'sender': sender}
                tpl = icp.get_param('coastbus.http_body') or '{"to": "{phone}", "message": "{message}"}'
                body = tpl
                for k, v in fill.items():
                    body = body.replace('{' + k + '}', json.dumps(v)[1:-1] if tpl.strip().startswith('{') else requests.utils.quote(v))
                url_f = url
                for k, v in fill.items():
                    url_f = url_f.replace('{' + k + '}', requests.utils.quote(v))
                r = requests.request(method, url_f, data=body.encode() if method != 'GET' else None, headers=headers, timeout=20)
                r.raise_for_status()
                self.provider_ref = r.text[:60]
            else:
                self.write({'state': 'no_provider'})
                return
            self.write({'state': 'sent', 'sent_at': fields.Datetime.now(), 'error': False})
        except Exception as e:
            _logger.warning('Courier SMS to %s failed: %s', self.phone, e)
            self.write({'state': 'failed' if self.tries >= 3 else 'queued', 'error': str(e)[:250]})

    def action_requeue(self):
        self.write({'state': 'queued', 'tries': 0, 'error': False})
        return True

    @api.model
    def action_send_test(self, phone):
        sms = self.create({'phone': phone, 'body': _('Coast Bus Courier test SMS.'), 'kind': 'test'})
        provider = self.env['ir.config_parameter'].sudo().get_param('coastbus.sms_provider') or 'none'
        sms._send_one(provider)
        return sms
