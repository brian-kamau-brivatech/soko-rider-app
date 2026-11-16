import hashlib
import math
import re
import secrets

PIN_ROUNDS = 3000


def hash_pin(pin, salt):
    """Same as the handheld app: sha256 chained PIN_ROUNDS times (lets the terminal check PINs offline)."""
    h = hashlib.sha256((salt + pin).encode()).hexdigest()
    for _ in range(PIN_ROUNDS - 1):
        h = hashlib.sha256((salt + h).encode()).hexdigest()
    return h


def new_salt():
    return secrets.token_hex(8)


def otp_hash(otp, waybill_no):
    return hashlib.sha256(f'{waybill_no}:{otp}'.encode()).hexdigest()


def norm_phone(phone):
    """Kenyan numbers to +2547XXXXXXXX / +2541XXXXXXXX; anything else returned trimmed."""
    p = re.sub(r'[^\d+]', '', phone or '')
    if p.startswith('+'):
        return p
    if p.startswith('254') and len(p) == 12:
        return '+' + p
    if p.startswith('0') and len(p) == 10:
        return '+254' + p[1:]
    if len(p) == 9 and p[0] in '17':
        return '+254' + p
    return p


def mask_phone(phone):
    p = phone or ''
    return p[:-6] + '***' + p[-3:] if len(p) > 6 else p


def mask_name(name):
    parts = (name or '').split()
    if not parts:
        return ''
    return ' '.join([parts[0]] + [w[0] + '.' for w in parts[1:]])


def charge(route, cfg, weight, length=0, width=0, height=0, declared=0.0, insured=False, pieces=1):
    """Fare rule shared with the app (lib/fare.dart). Returns a dict of amounts."""
    divisor = cfg.get('vol_divisor') or 5000
    vol = (length or 0) * (width or 0) * (height or 0) / divisor if divisor else 0
    chargeable = max(weight or 0, vol)
    extra_kg = max(0, math.ceil(round(chargeable - route.base_kg, 3))) if chargeable > route.base_kg else 0
    fare = route.base_fare + extra_kg * route.rate_per_kg + max(0, (pieces or 1) - 1) * route.extra_piece_fee
    fare = max(fare, route.min_charge)
    ins = 0.0
    if insured and declared:
        ins = max(round(declared * (cfg.get('insurance_pct') or 0) / 100.0), cfg.get('insurance_min') or 0)
    total = round(fare + ins, 2)
    vat_pct = cfg.get('vat_pct') or 0
    vat = round(total * vat_pct / (100 + vat_pct), 2) if vat_pct else 0
    return {'vol_weight': round(vol, 2), 'chargeable_weight': round(chargeable, 2), 'fare': round(fare, 2),
            'insurance': ins, 'total': total, 'vat_amount': vat}
