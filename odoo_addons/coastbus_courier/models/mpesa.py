import base64
import logging
from datetime import datetime

import requests

from odoo import _, api, fields, models
from odoo.exceptions import UserError

from .common import norm_phone

_logger = logging.getLogger(__name__)


class CourierMpesa(models.Model):
    """M-Pesa STK push (Daraja) started from a handheld at the counter."""
    _name = 'courier.mpesa'
    _description = 'Courier M-Pesa STK Request'
    _order = 'id desc'

    name = fields.Char('Reference', required=True)
    phone = fields.Char(required=True)
    amount = fields.Float(required=True)
    state = fields.Selection([('pending', 'Waiting for customer'), ('paid', 'Paid'), ('failed', 'Failed / cancelled')], default='pending', index=True)
    checkout_id = fields.Char('CheckoutRequestID', index=True)
    receipt = fields.Char('M-Pesa receipt', index=True)
    result_desc = fields.Char()
    device_id = fields.Many2one('courier.device')
    staff_id = fields.Many2one('courier.staff')
    waybill_name = fields.Char('For waybill')
    paid_at = fields.Datetime()

    # ------------------------------------------------------------------ Daraja
    @api.model
    def _conf(self):
        icp = self.env['ir.config_parameter'].sudo()
        g = lambda k, d='': icp.get_param('coastbus.mpesa_' + k) or d
        c = {'env': g('env', 'sandbox'), 'key': g('consumer_key'), 'secret': g('consumer_secret'), 'shortcode': g('shortcode'),
             'passkey': g('passkey'), 'type': g('type', 'paybill'), 'till': g('till'),
             'callback': g('callback_url') or (icp.get_param('web.base.url') or '').rstrip('/') + '/courier/mpesa/callback'}
        c['base'] = 'https://api.safaricom.co.ke' if c['env'] == 'production' else 'https://sandbox.safaricom.co.ke'
        return c

    @api.model
    def _token(self, c):
        r = requests.get(c['base'] + '/oauth/v1/generate?grant_type=client_credentials', auth=(c['key'], c['secret']), timeout=20)
        r.raise_for_status()
        return r.json()['access_token']

    @api.model
    def start(self, phone, amount, ref, device=None, staff=None):
        c = self._conf()
        if not (c['key'] and c['secret'] and c['shortcode'] and c['passkey']):
            raise UserError(_('M-Pesa STK push is not set up. Ask the administrator (Courier settings → M-Pesa).'))
        phone = norm_phone(phone).lstrip('+')
        if not (phone.startswith('254') and len(phone) == 12):
            raise UserError(_('Enter a valid Safaricom number.'))
        amount = int(round(amount))
        if amount < 1:
            raise UserError(_('Amount must be at least 1.'))
        ts = datetime.now().strftime('%Y%m%d%H%M%S')
        pwd = base64.b64encode((c['shortcode'] + c['passkey'] + ts).encode()).decode()
        buy_goods = c['type'] == 'till'
        body = {
            'BusinessShortCode': c['shortcode'], 'Password': pwd, 'Timestamp': ts,
            'TransactionType': 'CustomerBuyGoodsOnline' if buy_goods else 'CustomerPayBillOnline',
            'Amount': amount, 'PartyA': phone, 'PartyB': (c['till'] or c['shortcode']) if buy_goods else c['shortcode'],
            'PhoneNumber': phone, 'CallBackURL': c['callback'], 'AccountReference': (ref or 'COURIER')[:12],
            'TransactionDesc': 'Courier',
        }
        rec = self.sudo().create({'name': ref or 'COURIER', 'phone': phone, 'amount': amount, 'device_id': device.id if device else False,
                                  'staff_id': staff.id if staff else False, 'waybill_name': ref})
        try:
            r = requests.post(c['base'] + '/mpesa/stkpush/v1/processrequest', json=body,
                              headers={'Authorization': 'Bearer ' + self._token(c)}, timeout=30)
            data = r.json()
        except Exception as e:
            rec.write({'state': 'failed', 'result_desc': str(e)[:200]})
            raise UserError(_('Could not reach M-Pesa: %s') % e)
        if data.get('ResponseCode') != '0':
            rec.write({'state': 'failed', 'result_desc': data.get('errorMessage') or data.get('ResponseDescription') or str(data)[:200]})
            raise UserError(rec.result_desc)
        rec.checkout_id = data.get('CheckoutRequestID')
        return rec

    def query(self):
        """Ask Daraja directly (when the callback is late or blocked)."""
        c = self._conf()
        for rec in self.filtered(lambda r: r.state == 'pending' and r.checkout_id):
            ts = datetime.now().strftime('%Y%m%d%H%M%S')
            pwd = base64.b64encode((c['shortcode'] + c['passkey'] + ts).encode()).decode()
            try:
                r = requests.post(c['base'] + '/mpesa/stkpushquery/v1/query',
                                  json={'BusinessShortCode': c['shortcode'], 'Password': pwd, 'Timestamp': ts, 'CheckoutRequestID': rec.checkout_id},
                                  headers={'Authorization': 'Bearer ' + self._token(c)}, timeout=20)
                data = r.json()
            except Exception as e:
                _logger.info('STK query failed: %s', e)
                continue
            code = str(data.get('ResultCode', ''))
            if code and code != '0' and code not in ('500.001.1001',):
                rec.write({'state': 'failed', 'result_desc': data.get('ResultDesc')})
            # paid status (with the receipt) arrives by callback

    @api.model
    def callback(self, payload):
        cb = (payload.get('Body') or {}).get('stkCallback') or {}
        rec = self.sudo().search([('checkout_id', '=', cb.get('CheckoutRequestID'))], limit=1)
        if not rec:
            return False
        if cb.get('ResultCode') == 0:
            items = {i.get('Name'): i.get('Value') for i in (cb.get('CallbackMetadata') or {}).get('Item', [])}
            rec.write({'state': 'paid', 'receipt': items.get('MpesaReceiptNumber'), 'paid_at': fields.Datetime.now(),
                       'result_desc': cb.get('ResultDesc')})
        else:
            rec.write({'state': 'failed', 'result_desc': cb.get('ResultDesc')})
        return True
