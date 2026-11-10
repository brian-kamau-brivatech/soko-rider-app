"""Licences by days, made by BRV with its private key and checked here with the public key.

A licence is for ONE computer (its machine code) and ends on a date (issue date + days). Without a valid
licence the app keeps watching but does not sign; PDFs stay in Input until a licence is entered.
Turning the computer clock back is noticed.
"""
import base64
import struct
from datetime import date, timedelta

from .secure import machine_code

PUBLIC_KEY = bytes.fromhex("fd61709630db5b1d71b54f816201e8179df0f9a9c1884afd8303051b021ba89e")
EPOCH = date(2024, 1, 1)
FMT = ">B5sHHI"  # version, machine (5 bytes), issued day, expiry day, serial
CONTACT = "BRV Integrated Systems  |  +254 181 914 810  |  brivatechventures@gmail.com"


def _b32(raw):
    return base64.b32encode(raw).decode().rstrip("=")


def _unb32(s):
    s = s.upper().replace("-", "").replace(" ", "").replace("\n", "").replace("\r", "")
    return base64.b32decode(s + "=" * (-len(s) % 8))


def machine_bytes(code):
    return _unb32(code)[:5]


def format_key(raw):
    s = _b32(raw)
    return "-".join(s[i:i + 5] for i in range(0, len(s), 5))


VERSION_PDF_ETR = 1
VERSION_POS = 2   # BRV POS (Android) licence
VERSION_TECH = 9  # BRV POS technician key (unlocks settings, 2 days); never a licence


def make(private_key, code, days, serial, issued=None, version=VERSION_PDF_ETR):
    """Used by the BRV licence maker only (needs the private key)."""
    issued = issued or date.today()
    exp = issued + timedelta(days=int(days))
    body = struct.pack(FMT, int(version), machine_bytes(code), (issued - EPOCH).days, (exp - EPOCH).days, int(serial))
    return format_key(body + private_key.sign(body)), exp


def read(key):
    """(info dict, error). info: machine, issued, expires, serial."""
    try:
        raw = _unb32(key)
    except Exception:
        return None, "This is not a licence key."
    n = struct.calcsize(FMT)
    if len(raw) != n + 64:
        return None, "This is not a licence key (wrong length)."
    body, sig = raw[:n], raw[n:]
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
        Ed25519PublicKey.from_public_bytes(PUBLIC_KEY).verify(sig, body)
    except Exception:
        return None, "This licence key is not valid."
    ver, mach, iss, exp, serial = struct.unpack(FMT, body)
    if ver == VERSION_TECH:
        return None, "This is a BRV POS technician key, not a licence."
    return {"machine": _b32(mach)[:4] + "-" + _b32(mach)[4:8], "issued": EPOCH + timedelta(days=iss),
            "expires": EPOCH + timedelta(days=exp), "serial": serial}, ""


def status(settings, today=None):
    """{'ok', 'state', 'message', 'days_left', 'expires'}. state: ok | warn | expired | none | clock | other_pc"""
    today = today or date.today()
    key = (settings.get("licence") or "").strip()
    last = settings.get("last_seen") or ""
    try:
        last_d = date.fromisoformat(last) if last else None
    except ValueError:
        last_d = None
    if last_d and today < last_d - timedelta(days=1):
        return {"ok": False, "state": "clock", "days_left": 0, "expires": None,
                "message": "The computer date (%s) is earlier than a date already used (%s). Set the correct date."
                           % (today.isoformat(), last_d.isoformat())}
    if not key:
        return {"ok": False, "state": "none", "days_left": 0, "expires": None,
                "message": "No licence. Send machine code %s to BRV to get one." % machine_code()}
    info, err = read(key)
    if not info:
        return {"ok": False, "state": "none", "days_left": 0, "expires": None, "message": err}
    if info["machine"] != machine_code():
        return {"ok": False, "state": "other_pc", "days_left": 0, "expires": info["expires"],
                "message": "This licence is for another computer (%s). This computer is %s."
                           % (info["machine"], machine_code())}
    left = (info["expires"] - today).days
    if left < 0:
        return {"ok": False, "state": "expired", "days_left": left, "expires": info["expires"],
                "message": "The licence ended on %s. Contact BRV to renew." % info["expires"].strftime("%d/%m/%Y")}
    return {"ok": True, "state": "warn" if left <= 7 else "ok", "days_left": left, "expires": info["expires"],
            "message": "Licensed until %s (%d day%s left)." % (info["expires"].strftime("%d/%m/%Y"), left,
                                                               "" if left == 1 else "s")}


def touch(settings, today=None):
    """Remember the newest date seen (to notice the clock being turned back)."""
    today = (today or date.today()).isoformat()
    if (settings.get("last_seen") or "") < today:
        settings["last_seen"] = today
        settings.save()
