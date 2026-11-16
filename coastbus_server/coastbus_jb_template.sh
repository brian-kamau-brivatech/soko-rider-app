#!/bin/bash
# Coast Bus Courier on jb: new light database in container BRV_2.0 (dbfilter ^%d$  ->  DB name = subdomain).
# First run: creates the database (Kenya/KES), installs coastbus_courier, sets admin login + random password.
# Later runs: backup, then update the module only.
#   EMAIL=you@example.com bash coastbus_jb.sh            (DB defaults to "coastbus")
set -e
C=${C:-BRV_2.0}; DB=${DB:-coastbus}; EMAIL=${EMAIL:-admin}
DOMAIN=$DB.brvsystems.co.ke
[[ "$DB" =~ ^[a-z0-9]+$ ]] || { echo "DB must be lowercase letters/digits"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$C" || { echo "container $C not running"; exit 1; }

echo "== 1/5 find the custom addons folder of $C"
AP=$(docker exec $C sh -c "grep -E '^\s*addons_path' /etc/odoo/odoo.conf | cut -d= -f2" | tr -d ' ')
HOSTDIR=""; INNER=""
for p in ${AP//,/ }; do
  src=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$p\"}}{{.Source}}{{end}}{{end}}" $C)
  if [ -n "$src" ] && [ -d "$src" ]; then HOSTDIR=$src; INNER=$p; break; fi
done
[ -n "$HOSTDIR" ] || { echo "No host-mounted addons folder found in addons_path=$AP"; exit 1; }
echo "   $INNER  <-  $HOSTDIR"

echo "== 2/5 module files"
TS=$(date +%Y%m%d_%H%M%S); mkdir -p /root/backups
[ -d $HOSTDIR/coastbus_courier ] && mv $HOSTDIR/coastbus_courier /root/backups/coastbus_courier_old_$TS
echo '__MODULE_TGZ__' | base64 -d | tar xz -C $HOSTDIR
chmod -R a+rX $HOSTDIR/coastbus_courier
docker exec $C ls $INNER/coastbus_courier/__manifest__.py >/dev/null

ODOO="docker exec -i $C odoo"
OPTS="-c /etc/odoo/odoo.conf -d $DB --no-http"
EXISTS=$(docker exec $C python3 -c "
import configparser,psycopg2
c=configparser.ConfigParser(); c.read('/etc/odoo/odoo.conf'); o=c['options']
k=dict(host=o.get('db_host','db'),port=o.get('db_port','5432'),user=o.get('db_user','odoo'),password=o.get('db_password',''),dbname='postgres')
cur=psycopg2.connect(**k).cursor(); cur.execute('select 1 from pg_database where datname=%s',('$DB',)); print('yes' if cur.fetchone() else 'no')")

if [ "$EXISTS" = "no" ]; then
  echo "== 3/5 new database $DB (base, then Kenya company, then courier + accounting) - 2 to 4 minutes"
  $ODOO $OPTS -i base --without-demo=all --stop-after-init 2>&1 | grep -a -i "error\|critical\|Traceback\|Modules loaded" | tail -3
  PW=$(openssl rand -base64 12 | tr -d '/+=')
  $ODOO shell $OPTS 2>&1 <<PYEOF | grep -a "DONE\|Error\|Traceback"
admin = env.ref('base.user_admin')
admin.write({'login': '$EMAIL', 'password': '$PW', 'tz': 'Africa/Nairobi'})
env.ref('base.KES').active = True
env.company.write({'name': 'Coast Bus Courier', 'country_id': env.ref('base.ke').id, 'currency_id': env.ref('base.KES').id})
icp = env['ir.config_parameter'].sudo()
icp.set_param('web.base.url', 'https://$DOMAIN')
icp.set_param('web.base.url.freeze', 'True')
env.cr.commit()
print('DONE')
PYEOF
  $ODOO $OPTS -i contacts,coastbus_courier --without-demo=all --stop-after-init 2>&1 | grep -a -i "error\|critical\|Traceback\|Modules loaded" | tail -3
  $ODOO shell $OPTS 2>&1 <<'PYEOF' | grep -a "DONE\|Error\|Traceback"
Tax = env['account.tax']
base = Tax.search([('type_tax_use', '=', 'sale'), ('amount', '=', 16), ('price_include', '=', False)], limit=1)
if base:
    inc = Tax.search([('type_tax_use', '=', 'sale'), ('amount', '=', 16), ('price_include', '=', True)], limit=1) or base.copy({'name': 'VAT 16% (included)', 'price_include': True})
    env['ir.config_parameter'].set_param('coastbus.tax_id', inc.id)
j = env['account.journal'].search([('code', '=', 'MPESA')], limit=1) or env['account.journal'].create({'name': 'M-Pesa', 'code': 'MPESA', 'type': 'bank'})
env['ir.config_parameter'].set_param('coastbus.mpesa_journal_id', j.id)
env.cr.commit()
print('DONE accounting: chart', env.company.chart_template, '| VAT incl', bool(base), '| M-Pesa journal ok')
PYEOF
  NEW=1
else
  echo "== 3/5 database $DB exists: backup, then update the module"
  docker exec $C python3 -c "
import configparser,os
c=configparser.ConfigParser(); c.read('/etc/odoo/odoo.conf'); o=c['options']
os.environ['PGPASSWORD']=o.get('db_password','')
os.execvp('pg_dump',['pg_dump','-h',o.get('db_host','db'),'-p',o.get('db_port','5432'),'-U',o.get('db_user','odoo'),'-Fc','$DB'])" > /root/backups/${DB}_$TS.dump \
    && ls -lh /root/backups/${DB}_$TS.dump || echo "   (backup skipped: pg_dump not available in $C)"
  $ODOO $OPTS -u coastbus_courier --stop-after-init 2>&1 | grep -a -i "error\|critical\|Traceback\|Modules loaded" | tail -3
fi

echo "== 4/5 reload Odoo so the web workers serve the courier API (about 10 seconds)"
docker restart $C >/dev/null && sleep 12
echo "== 5/5 check"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" http://localhost:8067/courier/api/v1/ping || true)
echo "   local API ping (Host $DOMAIN): HTTP $code"
echo
echo "URL: https://$DOMAIN    Terminals: server address $DOMAIN"
[ -n "$NEW" ] && echo "Login: $EMAIL   Password: $PW   (shown once - save it)"
exit 0
