"""BRV Cloud: licences and sync for BRV Pos Manager / BRV Pos Sales, managed with the BRV Licence app.

- A company (client) has a licence end date and a limit of user (sales) devices.
- A device shows a code; the developer binds a Manager device to a company, the manager binds Sales devices.
- Devices sell offline and sync rows (products, stock moves, sales, accounts ...) through /api/sync.
"""
import datetime as dt
import hashlib
import hmac
import json
import os
import secrets

import psycopg
from fastapi import Body, FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

DSN = os.environ.get('DATABASE_URL', 'postgresql://brv:brv@localhost:5432/brv_cloud')
DEV_KEY = os.environ.get('DEV_KEY', '')
PULL_LIMIT = 1500

app = FastAPI(title='BRV Cloud', docs_url=None, redoc_url=None)

SCHEMA = """
CREATE SEQUENCE IF NOT EXISTS rev_seq;
CREATE TABLE IF NOT EXISTS companies(
  id SERIAL PRIMARY KEY, name TEXT NOT NULL, phone TEXT DEFAULT '', email TEXT DEFAULT '', notes TEXT DEFAULT '',
  expires_at TIMESTAMPTZ NOT NULL, max_devices INT NOT NULL DEFAULT 2, active BOOLEAN NOT NULL DEFAULT TRUE,
  seeded BOOLEAN NOT NULL DEFAULT FALSE, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS devices(
  id SERIAL PRIMARY KEY, company_id INT NOT NULL REFERENCES companies(id), code TEXT NOT NULL UNIQUE,
  secret_hash TEXT NOT NULL, role TEXT NOT NULL, device_no INT NOT NULL, name TEXT DEFAULT '', model TEXT DEFAULT '',
  token_hash TEXT DEFAULT '', active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen TIMESTAMPTZ, last_sync TIMESTAMPTZ);
CREATE TABLE IF NOT EXISTS hellos(
  code TEXT PRIMARY KEY, secret_hash TEXT NOT NULL, app TEXT NOT NULL, model TEXT DEFAULT '', name TEXT DEFAULT '',
  first_seen TIMESTAMPTZ NOT NULL DEFAULT now(), last_seen TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS records(
  company_id INT NOT NULL, tbl TEXT NOT NULL, rid TEXT NOT NULL, data JSONB, deleted BOOLEAN NOT NULL DEFAULT FALSE,
  rev BIGINT NOT NULL DEFAULT nextval('rev_seq'), device_id INT, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY(company_id, tbl, rid));
CREATE INDEX IF NOT EXISTS records_rev ON records(company_id, rev);
"""


def db():
    return psycopg.connect(DSN, row_factory=dict_row, autocommit=False)


@app.on_event('startup')
def _init():
    with db() as c:
        c.execute(SCHEMA)


def _h(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()


def _now():
    return dt.datetime.now(dt.timezone.utc)


def _iso(t):
    return t.isoformat() if t else None


def _days_left(expires):
    """Whole days left, counting today (expires in 3h -> 1)."""
    sec = (expires - _now()).total_seconds()
    return 0 if sec <= 0 else int(-(-sec // 86400))


def _err(http_code, msg, **extra):
    return JSONResponse(status_code=http_code, content={'ok': False, 'error': msg, **extra})


def _licence(c, company_id):
    co = c.execute('SELECT * FROM companies WHERE id = %s', (company_id,)).fetchone()
    used = c.execute("SELECT COUNT(*) n FROM devices WHERE company_id = %s AND role = 'sales' AND active", (company_id,)).fetchone()['n']
    return co, {
        'company_id': co['id'], 'company': co['name'], 'expires_at': _iso(co['expires_at']), 'days_left': _days_left(co['expires_at']),
        'active': co['active'], 'max_devices': co['max_devices'], 'devices_used': used, 'server_time': _iso(_now()),
        'seeded': co['seeded'],
    }


# -----------------------------------------------------------------------------
# Devices: show a code, wait until bound, get a token
# -----------------------------------------------------------------------------
@app.post('/api/hello')
def hello(body: dict = Body(...)):
    code = str(body.get('code', '')).strip().upper()
    secret = str(body.get('secret', ''))
    appname = 'manager' if body.get('app') == 'manager' else 'sales'
    if len(code) < 8 or len(secret) < 16:
        return _err(400, 'Bad device code.')
    with db() as c:
        d = c.execute('SELECT * FROM devices WHERE code = %s', (code,)).fetchone()
        if not d:
            c.execute(
                'INSERT INTO hellos(code, secret_hash, app, model, name) VALUES (%s,%s,%s,%s,%s) '
                'ON CONFLICT (code) DO UPDATE SET last_seen = now(), model = EXCLUDED.model, name = EXCLUDED.name '
                'WHERE hellos.secret_hash = EXCLUDED.secret_hash',
                (code, _h(secret), appname, str(body.get('model', ''))[:80], str(body.get('name', ''))[:80]))
            return {'ok': True, 'status': 'waiting', 'code': code}
        if not hmac.compare_digest(d['secret_hash'], _h(secret)):
            return _err(403, 'This code belongs to another device.')
        if not d['active']:
            return {'ok': True, 'status': 'revoked'}
        co, lic = _licence(c, d['company_id'])
        token = secrets.token_urlsafe(32)
        c.execute('UPDATE devices SET token_hash = %s, last_seen = now(), model = %s WHERE id = %s',
                  (_h(token), str(body.get('model', ''))[:80], d['id']))
        status = 'active' if co['active'] and lic['days_left'] > 0 else ('suspended' if not co['active'] else 'expired')
        return {'ok': True, 'status': status, 'token': token, 'device_id': d['id'], 'device_no': d['device_no'],
                'role': d['role'], 'licence': lic}


def _device(c, authorization):
    tok = (authorization or '').removeprefix('Bearer ').strip()
    if not tok:
        raise HTTPException(401, 'No token')
    d = c.execute('SELECT * FROM devices WHERE token_hash = %s', (_h(tok),)).fetchone()
    if not d:
        raise HTTPException(401, 'Unknown device')
    return d


def _bind(c, company_id, code, role, name=''):
    code = code.strip().upper()
    h = c.execute('SELECT * FROM hellos WHERE code = %s', (code,)).fetchone()
    if not h:
        if c.execute('SELECT 1 FROM devices WHERE code = %s', (code,)).fetchone():
            return 'This device is already registered.'
        return 'Code not found. Open the app on that device (with internet) so it shows its code, then try again.'
    if h['app'] != role:
        return 'That code is from the %s app; it can only be added as a %s device.' % (h['app'].title(), h['app'])
    co = c.execute('SELECT * FROM companies WHERE id = %s FOR UPDATE', (company_id,)).fetchone()
    if role == 'sales':
        used = c.execute("SELECT COUNT(*) n FROM devices WHERE company_id = %s AND role = 'sales' AND active", (company_id,)).fetchone()['n']
        if used >= co['max_devices']:
            return 'Device limit reached (%d of %d). Ask BRV to allow more devices.' % (used, co['max_devices'])
    else:
        c.execute("UPDATE devices SET active = FALSE WHERE company_id = %s AND role = 'manager'", (company_id,))
    no = c.execute('SELECT COALESCE(MAX(device_no), 0) + 1 n FROM devices WHERE company_id = %s', (company_id,)).fetchone()['n']
    c.execute('INSERT INTO devices(company_id, code, secret_hash, role, device_no, name, model) VALUES (%s,%s,%s,%s,%s,%s,%s)',
              (company_id, code, h['secret_hash'], role, no, name or h['name'] or ('Manager' if role == 'manager' else 'Device %d' % no), h['model']))
    c.execute('DELETE FROM hellos WHERE code = %s', (code,))
    return None


def _devices(c, company_id):
    return [{'id': r['id'], 'code': r['code'], 'role': r['role'], 'device_no': r['device_no'], 'name': r['name'], 'model': r['model'],
             'active': r['active'], 'last_seen': _iso(r['last_seen']), 'last_sync': _iso(r['last_sync'])}
            for r in c.execute('SELECT * FROM devices WHERE company_id = %s ORDER BY active DESC, device_no', (company_id,)).fetchall()]


# -----------------------------------------------------------------------------
# Manager app: user devices of the company
# -----------------------------------------------------------------------------
@app.get('/api/devices')
def list_devices(authorization: str = Header(None)):
    with db() as c:
        d = _device(c, authorization)
        co, lic = _licence(c, d['company_id'])
        return {'ok': True, 'devices': _devices(c, d['company_id']), 'licence': lic, 'me': d['id']}


@app.post('/api/devices')
def add_device(body: dict = Body(...), authorization: str = Header(None)):
    with db() as c:
        d = _device(c, authorization)
        if d['role'] != 'manager' or not d['active']:
            return _err(403, 'Only the manager app can add devices.')
        err = _bind(c, d['company_id'], str(body.get('code', '')), 'sales', str(body.get('name', ''))[:60])
        if err:
            c.rollback()
            return _err(400, err)
        co, lic = _licence(c, d['company_id'])
        return {'ok': True, 'devices': _devices(c, d['company_id']), 'licence': lic}


@app.delete('/api/devices/{device_id}')
def remove_device(device_id: int, authorization: str = Header(None)):
    with db() as c:
        d = _device(c, authorization)
        if d['role'] != 'manager' or not d['active']:
            return _err(403, 'Only the manager app can remove devices.')
        n = c.execute("UPDATE devices SET active = FALSE, token_hash = '' WHERE id = %s AND company_id = %s AND role = 'sales'",
                      (device_id, d['company_id'])).rowcount
        if not n:
            return _err(404, 'Device not found.')
        co, lic = _licence(c, d['company_id'])
        return {'ok': True, 'devices': _devices(c, d['company_id']), 'licence': lic}


# -----------------------------------------------------------------------------
# Sync
# -----------------------------------------------------------------------------
@app.post('/api/sync')
def sync(body: dict = Body(...), authorization: str = Header(None)):
    with db() as c:
        d = _device(c, authorization)
        if not d['active']:
            return _err(403, 'This device was removed from the company.', status='revoked')
        co, lic = _licence(c, d['company_id'])
        if not co['active']:
            return _err(402, 'The licence is suspended. Contact BRV Integrated Systems.', status='suspended', licence=lic)
        if lic['days_left'] <= 0:
            return _err(402, 'The licence has expired. Contact BRV Integrated Systems.', status='expired', licence=lic)
        push = body.get('push') or []
        for r in push:
            tbl, rid = str(r.get('tbl', ''))[:40], str(r.get('rid', ''))[:80]
            if not tbl or not rid:
                continue
            c.execute(
                'INSERT INTO records(company_id, tbl, rid, data, deleted, device_id) VALUES (%s,%s,%s,%s,%s,%s) '
                'ON CONFLICT (company_id, tbl, rid) DO UPDATE SET data = EXCLUDED.data, deleted = EXCLUDED.deleted, '
                "rev = nextval('rev_seq'), device_id = EXCLUDED.device_id, updated_at = now()",
                (d['company_id'], tbl, rid, Jsonb(r.get('data')) if not r.get('deleted') else None, bool(r.get('deleted')), d['id']))
        if push and not co['seeded']:
            c.execute('UPDATE companies SET seeded = TRUE WHERE id = %s', (co['id'],))
            lic['seeded'] = True
        since = int(body.get('since') or 0)
        rows = c.execute('SELECT tbl, rid, data, deleted, rev, device_id FROM records WHERE company_id = %s AND rev > %s '
                         'ORDER BY rev LIMIT %s', (d['company_id'], since, PULL_LIMIT)).fetchall()
        cursor = rows[-1]['rev'] if rows else since
        pull = [{'tbl': r['tbl'], 'rid': r['rid'], 'data': r['data'], 'deleted': r['deleted']} for r in rows if r['device_id'] != d['id']]
        c.execute('UPDATE devices SET last_seen = now(), last_sync = now() WHERE id = %s', (d['id'],))
        return {'ok': True, 'pull': pull, 'rev': cursor, 'more': len(rows) == PULL_LIMIT, 'pushed': len(push), 'licence': lic}


# -----------------------------------------------------------------------------
# Developer (BRV Licence app)
# -----------------------------------------------------------------------------
def _dev(key):
    if not DEV_KEY or not key or not hmac.compare_digest(DEV_KEY, key):
        raise HTTPException(401, 'Wrong developer key')


def _company_out(c, co):
    used = c.execute("SELECT COUNT(*) n FROM devices WHERE company_id = %s AND role = 'sales' AND active", (co['id'],)).fetchone()['n']
    mgr = c.execute("SELECT name, model, last_seen FROM devices WHERE company_id = %s AND role = 'manager' AND active", (co['id'],)).fetchone()
    return {'id': co['id'], 'name': co['name'], 'phone': co['phone'], 'email': co['email'], 'notes': co['notes'],
            'expires_at': _iso(co['expires_at']), 'days_left': _days_left(co['expires_at']), 'active': co['active'],
            'max_devices': co['max_devices'], 'devices_used': used, 'has_manager': bool(mgr),
            'manager_seen': _iso(mgr['last_seen']) if mgr else None, 'created_at': _iso(co['created_at'])}


@app.get('/api/dev/companies')
def dev_companies(x_dev_key: str = Header(None)):
    _dev(x_dev_key)
    with db() as c:
        return {'ok': True, 'companies': [_company_out(c, co) for co in c.execute('SELECT * FROM companies ORDER BY name').fetchall()]}


@app.post('/api/dev/companies')
def dev_new_company(body: dict = Body(...), x_dev_key: str = Header(None)):
    _dev(x_dev_key)
    name = str(body.get('name', '')).strip()
    if not name:
        return _err(400, 'Enter the company name.')
    days = max(0, int(body.get('days') or 0))
    with db() as c:
        co = c.execute('INSERT INTO companies(name, phone, email, notes, expires_at, max_devices) VALUES (%s,%s,%s,%s,%s,%s) RETURNING *',
                       (name, str(body.get('phone', '')), str(body.get('email', '')), str(body.get('notes', '')),
                        _now() + dt.timedelta(days=days), max(0, int(body.get('max_devices') or 2)))).fetchone()
        return {'ok': True, 'company': _company_out(c, co)}


@app.get('/api/dev/companies/{cid}')
def dev_company(cid: int, x_dev_key: str = Header(None)):
    _dev(x_dev_key)
    with db() as c:
        co = c.execute('SELECT * FROM companies WHERE id = %s', (cid,)).fetchone()
        if not co:
            return _err(404, 'Company not found.')
        return {'ok': True, 'company': _company_out(c, co), 'devices': _devices(c, cid)}


@app.patch('/api/dev/companies/{cid}')
def dev_update_company(cid: int, body: dict = Body(...), x_dev_key: str = Header(None)):
    _dev(x_dev_key)
    with db() as c:
        co = c.execute('SELECT * FROM companies WHERE id = %s FOR UPDATE', (cid,)).fetchone()
        if not co:
            return _err(404, 'Company not found.')
        sets, args = [], []
        for k in ('name', 'phone', 'email', 'notes'):
            if k in body:
                sets.append('%s = %%s' % k)
                args.append(str(body[k]))
        if 'max_devices' in body:
            sets.append('max_devices = %s')
            args.append(max(0, int(body['max_devices'])))
        if 'active' in body:
            sets.append('active = %s')
            args.append(bool(body['active']))
        if body.get('add_days'):
            base = max(co['expires_at'], _now())
            sets.append('expires_at = %s')
            args.append(base + dt.timedelta(days=int(body['add_days'])))
        elif body.get('set_days') is not None:
            sets.append('expires_at = %s')
            args.append(_now() + dt.timedelta(days=int(body['set_days'])))
        if sets:
            c.execute('UPDATE companies SET %s WHERE id = %%s' % ', '.join(sets), (*args, cid))
        co = c.execute('SELECT * FROM companies WHERE id = %s', (cid,)).fetchone()
        return {'ok': True, 'company': _company_out(c, co), 'devices': _devices(c, cid)}


@app.post('/api/dev/companies/{cid}/bind')
def dev_bind(cid: int, body: dict = Body(...), x_dev_key: str = Header(None)):
    _dev(x_dev_key)
    with db() as c:
        if not c.execute('SELECT 1 FROM companies WHERE id = %s', (cid,)).fetchone():
            return _err(404, 'Company not found.')
        role = 'manager' if body.get('role', 'manager') == 'manager' else 'sales'
        err = _bind(c, cid, str(body.get('code', '')), role, str(body.get('name', ''))[:60])
        if err:
            c.rollback()
            return _err(400, err)
        co = c.execute('SELECT * FROM companies WHERE id = %s', (cid,)).fetchone()
        return {'ok': True, 'company': _company_out(c, co), 'devices': _devices(c, cid)}


@app.post('/api/dev/devices/{did}')
def dev_device(did: int, body: dict = Body(...), x_dev_key: str = Header(None)):
    _dev(x_dev_key)
    with db() as c:
        d = c.execute('SELECT * FROM devices WHERE id = %s', (did,)).fetchone()
        if not d:
            return _err(404, 'Device not found.')
        if 'active' in body:
            active = bool(body['active'])
            if active and d['role'] == 'sales':
                co = c.execute('SELECT * FROM companies WHERE id = %s', (d['company_id'],)).fetchone()
                used = c.execute("SELECT COUNT(*) n FROM devices WHERE company_id = %s AND role = 'sales' AND active", (d['company_id'],)).fetchone()['n']
                if used >= co['max_devices']:
                    return _err(400, 'Device limit reached. Raise the limit first.')
            c.execute("UPDATE devices SET active = %s, token_hash = CASE WHEN %s THEN token_hash ELSE '' END WHERE id = %s", (active, active, did))
        return {'ok': True, 'devices': _devices(c, d['company_id'])}


@app.get('/api/dev/waiting')
def dev_waiting(x_dev_key: str = Header(None)):
    _dev(x_dev_key)
    with db() as c:
        rows = c.execute("SELECT code, app, model, name, last_seen FROM hellos WHERE last_seen > now() - interval '2 days' ORDER BY last_seen DESC LIMIT 50").fetchall()
        return {'ok': True, 'waiting': [{**r, 'last_seen': _iso(r['last_seen'])} for r in rows]}


@app.get('/api/ping')
def ping():
    return {'ok': True, 'app': 'BRV Cloud', 'time': _iso(_now())}
