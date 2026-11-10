"""Hidden, encrypted storage tied to this computer.

Settings live in a hidden folder under the user's AppData, encrypted with a key made from this machine's
ID. Opening the file shows nothing readable; editing it by hand makes it invalid (detected); copying it to
another computer does not work.
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
import uuid

APP_SALT = b"BRV-PDF-ETR/2026/settings"


def machine_id():
    """A stable ID of this computer (Windows MachineGuid; /etc/machine-id elsewhere)."""
    if sys.platform.startswith("win"):
        try:
            import winreg
            k = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography", 0,
                               winreg.KEY_READ | getattr(winreg, "KEY_WOW64_64KEY", 0))
            v, _ = winreg.QueryValueEx(k, "MachineGuid")
            return str(v)
        except OSError:
            pass
    for p in ("/etc/machine-id", "/var/lib/dbus/machine-id"):
        try:
            with open(p) as f:
                v = f.read().strip()
                if v:
                    return v
        except OSError:
            pass
    return "node-%012x" % uuid.getnode()


def machine_code():
    """Short code the client reads out to BRV for a licence, e.g. 7K2P-9QXA."""
    h = hashlib.sha256(("BRV-ETR:" + machine_id()).encode()).digest()
    s = base64.b32encode(h[:5]).decode()
    return s[:4] + "-" + s[4:8]


def hidden_dir():
    if sys.platform.startswith("win"):
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        path = os.path.join(base, "BRV", ".etr")
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
        path = os.path.join(base, "BRV", ".etr")
    new = not os.path.isdir(path)
    os.makedirs(path, exist_ok=True)
    if new and sys.platform.startswith("win"):
        try:
            subprocess.run(["attrib", "+h", "+s", path], capture_output=True,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except OSError:
            pass
    return path


def _fernet():
    from cryptography.fernet import Fernet
    key = hashlib.pbkdf2_hmac("sha256", machine_id().encode(), APP_SALT, 100000)
    return Fernet(base64.urlsafe_b64encode(key))


class Tampered(Exception):
    pass


def save(path, data):
    blob = _fernet().encrypt(json.dumps(data, separators=(",", ":")).encode("utf-8"))
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(blob)
    if os.path.exists(path):
        try:
            os.replace(path, path + ".bak")
        except OSError:
            pass
    os.replace(tmp, path)


def load(path):
    """dict, or None if there is no file. Raises Tampered if it was edited or comes from another PC."""
    if not os.path.exists(path):
        return None
    from cryptography.fernet import InvalidToken
    with open(path, "rb") as f:
        blob = f.read()
    try:
        return json.loads(_fernet().decrypt(blob).decode("utf-8"))
    except (InvalidToken, ValueError):
        raise Tampered(path)


def hash_password(pw, salt=None):
    salt = salt or os.urandom(16).hex()
    h = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(salt), 120000).hex()
    return "%s$%s" % (salt, h)


def check_password(pw, stored):
    if not stored or "$" not in stored:
        return False
    salt, _ = stored.split("$", 1)
    import hmac
    return hmac.compare_digest(hash_password(pw, salt), stored)
