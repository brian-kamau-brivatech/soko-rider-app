"""Public tracking page: the link printed on receipts and sent by SMS (no login, no personal details)."""
from markupsafe import escape

from odoo import fields, http
from odoo.http import request

PAGE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Track parcel · {company}</title>
<style>
:root{{--ink:#0f2a4a;--acc:#e8a317;--ok:#15803d;--bad:#b91c1c;--muted:#64748b;--bg:#f4f6fa}}
*{{box-sizing:border-box}}body{{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:#0f172a}}
header{{background:var(--ink);color:#fff;padding:18px 16px}}header b{{font-size:18px}}header small{{display:block;color:#cbd5e1}}
main{{max-width:560px;margin:0 auto;padding:16px}}
form{{display:flex;gap:8px;margin:0 0 16px}}input{{flex:1;padding:12px;border:1px solid #cbd5e1;border-radius:10px;font-size:16px}}
button{{padding:12px 16px;border:0;border-radius:10px;background:var(--acc);color:#111;font-weight:700;font-size:15px}}
.card{{background:#fff;border-radius:14px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.08);margin-bottom:14px}}
.st{{display:inline-block;padding:6px 12px;border-radius:999px;font-weight:700;font-size:14px;background:#e0f2fe;color:var(--ink)}}
.st.arrived,.st.collected{{background:#dcfce7;color:var(--ok)}}.st.lost,.st.cancelled{{background:#fee2e2;color:var(--bad)}}
.row{{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #f1f5f9}}.row span{{color:var(--muted)}}
ol{{list-style:none;margin:0;padding:0}}li{{position:relative;padding:0 0 16px 22px}}
li:before{{content:"";position:absolute;left:4px;top:5px;width:10px;height:10px;border-radius:50%;background:var(--acc)}}
li:after{{content:"";position:absolute;left:8px;top:16px;bottom:0;width:2px;background:#e2e8f0}}li:last-child:after{{display:none}}
li small{{display:block;color:var(--muted)}}.muted{{color:var(--muted)}}
</style></head><body><header><b>{company}</b><small>Parcel tracking</small></header><main>
<form method="get" action="/track"><input name="no" placeholder="Waybill number" value="{q}" autocomplete="off"><button>Track</button></form>
{body}</main></body></html>"""


class CourierTrack(http.Controller):

    def _render(self, w, q=''):
        company = escape(request.env.company.sudo().name or 'Courier')
        if w is None:
            body = '<p class="muted">Enter the waybill number from your receipt.</p>' if not q else \
                '<div class="card"><b>Not found.</b><p class="muted">Check the waybill number on your receipt and try again.</p></div>'
        else:
            s = w.public_status()
            wtz = w.with_context(tz=w.env.user.tz or 'Africa/Nairobi')
            steps = ''.join(
                f'<li><b>{escape(st["text"])}</b><small>{escape(fields.Datetime.context_timestamp(wtz, st["at"]).strftime("%d %b %Y, %H:%M"))}</small></li>'
                for st in reversed(s['steps']))
            body = (f'<div class="card"><div class="row"><span>Waybill</span><b>{escape(s["name"])}</b></div>'
                    f'<div class="row"><span>From</span><b>{escape(s["from"])}</b></div><div class="row"><span>To</span><b>{escape(s["to"])}</b></div>'
                    f'<div class="row"><span>Receiver</span><b>{escape(s["receiver"])}</b></div><div class="row"><span>Pieces</span><b>{s["pieces"]}</b></div>'
                    f'<p style="margin:14px 0 0"><span class="st {s["state_key"]}">{escape(s["state"])}</span></p></div>'
                    f'<div class="card"><ol>{steps or "<li>Booked</li>"}</ol></div>')
            if s['state_key'] == 'arrived':
                body += '<div class="card">Bring your ID and the collection code sent to you by SMS.</div>'
        return request.make_response(PAGE.format(company=company, q=escape(q), body=body), headers=[('Content-Type', 'text/html; charset=utf-8')])

    @http.route('/t/<string:token>', type='http', auth='public', methods=['GET'], csrf=False)
    def by_token(self, token, **kw):
        w = request.env['courier.waybill'].sudo().search([('tracking_token', '=', token)], limit=1)
        return self._render(w or None, '')

    @http.route('/track', type='http', auth='public', methods=['GET'], csrf=False)
    def by_number(self, no='', **kw):
        no = (no or '').strip().upper()[:40]
        w = request.env['courier.waybill'].sudo().search([('name', '=', no.split('/')[0])], limit=1) if no else None
        return self._render(w or None, no)
