#!/bin/bash
# BRV Cloud: licences and sync for BRV Pos Manager / Sales and the BRV Licence app.
# Run on the server:  bash brv_cloud_install.sh   (or from a Mac: ssh root@SERVER 'bash -s' < brv_cloud_install.sh)
set -e
DIR=/opt/brv_cloud
DOMAIN=${DOMAIN:-pos.brvsystems.co.ke}
mkdir -p $DIR && cd $DIR
echo "== 1/4 files into $DIR"
echo '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' | base64 -d | tar xz -C $DIR
if [ ! -f .env ]; then
  echo "DB_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)" > .env
  echo "DEV_KEY=BRV-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28)" >> .env
  chmod 600 .env
  echo "   new keys made (.env)"
fi
if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
echo "== 2/4 start (database + API on port 8095)"
$DC up -d --build 2>&1 | tail -3
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8095/api/ping >/dev/null 2>&1; then break; fi; sleep 2
done
curl -fsS http://127.0.0.1:8095/api/ping && echo
echo "== 3/4 web address"
if command -v nginx >/dev/null 2>&1 && [ -d /etc/nginx/sites-available ]; then
  cat > /etc/nginx/sites-available/$DOMAIN <<NGX
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 20m;
    location / {
        proxy_pass http://127.0.0.1:8095;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
    }
}
NGX
  ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
  nginx -t && systemctl reload nginx && echo "   nginx: http://$DOMAIN -> port 8095"
else
  echo "   nginx not found on the host: the apps can use http://$(hostname -I | awk '{print $1}'):8095"
fi
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then ufw allow 8095/tcp >/dev/null && echo "   firewall: port 8095 open"; fi
echo "== 4/4 done"
echo "   Server check:  curl http://$DOMAIN/api/ping"
echo "   DEVELOPER KEY (for the BRV Licence app, keep it private):"
grep DEV_KEY .env | cut -d= -f2
