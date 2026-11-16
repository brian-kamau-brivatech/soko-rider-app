#!/bin/bash
# Coast Bus Courier server: Odoo 17 Community + PostgreSQL in Docker, with the coastbus_courier module.
# First run installs everything. Running it again updates the module (data and passwords are kept).
#   bash coastbus_install.sh                        -> http://SERVER-IP:8069
#   DOMAIN=courier.coastbus.co.ke bash coastbus_install.sh   -> https with a free certificate (needed for M-Pesa STK push)
set -e
DIR=/opt/coastbus
DB=coastbus
DOMAIN=${DOMAIN:-}
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo -i)"; exit 1; }

echo "== 1/6 Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || apt-get install -y docker-compose-plugin

echo "== 2/6 files in $DIR"
mkdir -p $DIR/addons $DIR/config $DIR/backups
cd $DIR
if [ ! -f .env ]; then
  echo "DB_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)" > .env
  echo "MASTER_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)" >> .env
  echo "ADMIN_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)" >> .env
  chmod 600 .env
  FIRST=1
fi
. ./.env
rm -rf addons/coastbus_courier
echo '__MODULE_TGZ__' | base64 -d | tar xz -C addons
cat > config/odoo.conf <<CONF
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
admin_passwd = $MASTER_PASSWORD
db_host = db
db_port = 5432
db_user = odoo
db_password = $DB_PASSWORD
db_name = $DB
dbfilter = ^$DB\$
list_db = False
proxy_mode = True
workers = 2
max_cron_threads = 1
limit_time_real = 600
gevent_port = 8072
CONF
cat > docker-compose.yml <<YML
services:
  db:
    image: postgres:15
    restart: always
    environment:
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_DB: postgres
    volumes:
      - pgdata:/var/lib/postgresql/data
  odoo:
    image: odoo:17.0
    restart: always
    depends_on: [db]
    ports:
      - "8069:8069"
      - "127.0.0.1:8072:8072"
    environment:
      TZ: Africa/Nairobi
    volumes:
      - odoodata:/var/lib/odoo
      - ./config:/etc/odoo:ro
      - ./addons:/mnt/extra-addons:ro
volumes:
  pgdata:
  odoodata:
YML
docker compose pull -q
docker compose up -d db
for i in $(seq 1 30); do docker compose exec -T db pg_isready -U odoo >/dev/null 2>&1 && break; sleep 2; done

RUN="docker compose run --rm -T odoo odoo"
OPTS="-c /etc/odoo/odoo.conf -d $DB --no-http"
if [ -n "$FIRST" ] || ! docker compose exec -T db psql -U odoo -lqt | cut -d'|' -f1 | grep -qw $DB; then
  echo "== 3/6 new database $DB (Kenya: KES, VAT 16%)"
  docker compose stop odoo >/dev/null 2>&1 || true
  $RUN $OPTS -i base --without-demo=all --load-language=en_US --stop-after-init
  $RUN shell $OPTS --log-level=warn <<PY
env.ref('base.user_admin').write({'password': '$ADMIN_PASSWORD', 'tz': 'Africa/Nairobi', 'name': 'Administrator'})
c = env.company
c.write({'name': 'Coast Bus Courier', 'country_id': env.ref('base.ke').id, 'currency_id': env.ref('base.KES').id})
env.ref('base.KES').active = True
env['ir.config_parameter'].set_param('web.base.url', '${DOMAIN:+https://$DOMAIN}' or 'http://$(curl -s -4 ifconfig.me || hostname -I | cut -d' ' -f1):8069')
env['ir.config_parameter'].set_param('web.base.url.freeze', 'True')
env.cr.commit()
PY
  echo "== 4/6 courier module + Kenyan accounting"
  $RUN $OPTS -i coastbus_courier --without-demo=all --stop-after-init
  $RUN shell $OPTS --log-level=warn <<'PY'
Tax = env['account.tax']
base = Tax.search([('type_tax_use', '=', 'sale'), ('amount', '=', 16), ('price_include', '=', False)], limit=1)
if base:
    inc = Tax.search([('type_tax_use', '=', 'sale'), ('amount', '=', 16), ('price_include', '=', True)], limit=1) or base.copy({'name': 'VAT 16% (included)', 'price_include': True, 'description': 'VAT 16% incl.'})
    env['ir.config_parameter'].set_param('coastbus.tax_id', inc.id)
mpesa = env['account.journal'].search([('code', '=', 'MPESA')], limit=1)
if not mpesa:
    mpesa = env['account.journal'].create({'name': 'M-Pesa', 'code': 'MPESA', 'type': 'bank'})
env['ir.config_parameter'].set_param('coastbus.mpesa_journal_id', mpesa.id)
env.cr.commit()
print('accounting ready: VAT incl.', bool(base), 'M-Pesa journal', mpesa.name)
PY
else
  echo "== 3/6 backup before update"
  docker compose exec -T db pg_dump -U odoo -Fc $DB > backups/${DB}_$(date +%Y%m%d_%H%M%S).dump
  ls -t backups/*.dump | tail -n +11 | xargs -r rm
  echo "== 4/6 update courier module"
  docker compose stop odoo
  $RUN $OPTS -u coastbus_courier --stop-after-init
fi

echo "== 5/6 start Odoo"
docker compose up -d odoo

if [ -n "$DOMAIN" ]; then
  echo "== 6/6 https for $DOMAIN"
  apt-get install -y -q nginx certbot python3-certbot-nginx >/dev/null
  cat > /etc/nginx/sites-available/coastbus <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 50m;
    proxy_read_timeout 720s;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    location /websocket { proxy_pass http://127.0.0.1:8072; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
    location / { proxy_pass http://127.0.0.1:8069; }
}
NGX
  ln -sf /etc/nginx/sites-available/coastbus /etc/nginx/sites-enabled/coastbus
  nginx -t && systemctl reload nginx
  certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --redirect || echo "!! certificate failed: point $DOMAIN to this server's IP, then run the script again"
  URL=https://$DOMAIN
else
  echo "== 6/6 no domain: plain http on port 8069"
  URL=http://$(curl -s -4 ifconfig.me || hostname -I | cut -d' ' -f1):8069
fi

# daily backup at 01:30, keep 14
cat > /etc/cron.d/coastbus-backup <<CRON
30 1 * * * root cd $DIR && docker compose exec -T db pg_dump -U odoo -Fc $DB > backups/${DB}_\$(date +\%Y\%m\%d).dump && ls -t backups/*.dump | tail -n +15 | xargs -r rm
CRON

sleep 5
echo
echo "================================================================"
echo " Coast Bus Courier is running:  $URL"
echo " Odoo login: admin    password: see /opt/coastbus/.env (ADMIN_PASSWORD)"
echo " Terminals: server address = ${URL#*://}"
echo "================================================================"
