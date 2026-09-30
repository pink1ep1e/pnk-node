#!/usr/bin/env bash
# pnk-node — CDN nginx (HTTPS → /api/uploadFile/ → 127.0.0.1:4443)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/common.sh"
else
  echo "Запускай из клона репозитория или через install.sh + PNK_NODE_RAW"; exit 1
fi
pnk_load_ui "${SCRIPT_DIR}"
pnk_require_root

CDN_DIR="/opt/cdn-nginx"
BACKEND_PORT="${CDN_BACKEND_PORT:-4443}"

pnk_clear
pnk_banner "CDN · nginx + LE"
pnk_section "CDN reverse-proxy"

pnk_ask "Домен CDN (A-запись → этот сервер)" DOMAIN "${DOMAIN:-}"
[[ -n "$DOMAIN" ]] || { pnk_err "Домен обязателен"; exit 1; }

LE_EMAIL_DEFAULT="admin@${DOMAIN}"
pnk_ask "Email для Let's Encrypt" LE_EMAIL "$LE_EMAIL_DEFAULT"
LE_EMAIL="${LE_EMAIL:-$LE_EMAIL_DEFAULT}"

pnk_ask "Бэкенд порт (xray upload)" BACKEND_PORT "$BACKEND_PORT"
BACKEND_PORT="${BACKEND_PORT:-4443}"

pnk_kv "domain" "$DOMAIN"
pnk_kv "backend" "127.0.0.1:${BACKEND_PORT}"

# ── packages ─────────────────────────────────────────────────────
pnk_step 1 6 "Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl certbot dnsutils >/dev/null

if ! command -v docker &>/dev/null; then
  pnk_info "Ставлю Docker..."
  apt-get install -y docker.io docker-compose-v2 >/dev/null 2>&1 \
    || curl -fsSL https://get.docker.com | sh
fi
# compose plugin
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-v2 >/dev/null 2>&1 || true
fi
systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || true
pnk_ok "Docker готов"

# ── conflicts ────────────────────────────────────────────────────
pnk_step 2 6 "Конфликты на 80/443"
if command -v nginx >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
  pnk_warn "Сношу системный nginx (конфликт с CDN)"
  systemctl stop nginx 2>/dev/null || true
  systemctl disable nginx 2>/dev/null || true
  apt-get remove -y nginx nginx-common nginx-core >/dev/null 2>&1 || true
fi
if command -v caddy >/dev/null 2>&1 && systemctl is-active --quiet caddy 2>/dev/null; then
  pnk_warn "Caddy активен и может занять 80/443 — останавливаю"
  systemctl stop caddy 2>/dev/null || true
fi
# stop old cdn container if reinstall
docker rm -f cdn-nginx >/dev/null 2>&1 || true

if ss -H -tlnp 2>/dev/null | grep -Eq ':80 |:443 '; then
  pnk_warn "Что-то ещё слушает 80/443:"
  ss -H -tlnp 2>/dev/null | grep -E ':80 |:443 ' || true
  if ! pnk_confirm "Продолжить?" "N"; then
    exit 1
  fi
else
  pnk_ok "Порты 80/443 свободны"
fi

# ── DNS ──────────────────────────────────────────────────────────
pnk_step 3 6 "DNS"
RESOLVED=""
if command -v dig >/dev/null 2>&1; then
  RESOLVED="$(dig +short "$DOMAIN" A 2>/dev/null | head -1 || true)"
elif command -v getent >/dev/null 2>&1; then
  RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
fi
if [[ -n "$RESOLVED" ]]; then
  pnk_kv "DNS A" "$RESOLVED"
else
  pnk_warn "Не удалось резолвить ${DOMAIN} — проверь A-запись"
fi
if ! pnk_confirm "DNS ок, выпускаем сертификат?" "Y"; then
  pnk_muted "Отменено"
  exit 0
fi

# ── certbot ──────────────────────────────────────────────────────
pnk_step 4 6 "Let's Encrypt"
certbot certonly --standalone -d "$DOMAIN" \
  --non-interactive --agree-tos -m "$LE_EMAIL" \
  --preferred-challenges http \
  || { pnk_err "certbot не выдал сертификат"; exit 1; }
[[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] || { pnk_err "Нет fullchain.pem"; exit 1; }
pnk_ok "Сертификат /etc/letsencrypt/live/${DOMAIN}/"

# UFW 80/443 if active
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp comment 'pnk-node CDN http' >/dev/null 2>&1 || true
  ufw allow 443/tcp comment 'pnk-node CDN https' >/dev/null 2>&1 || true
  pnk_ok "UFW: 80/443"
fi

# ── files ────────────────────────────────────────────────────────
pnk_step 5 6 "Конфиг /opt/cdn-nginx"
mkdir -p "${CDN_DIR}/html"
cd "${CDN_DIR}"

cat > docker-compose.yml <<EOF
services:
  cdn-nginx:
    image: nginx:1.28
    container_name: cdn-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - ./html:/usr/share/nginx/html:ro
EOF

cat > nginx.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /api/uploadFile/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        client_max_body_size 0;
    }

    location / {
        root /usr/share/nginx/html;
        index index.html;
        add_header Cache-Control "public, max-age=86400" always;
    }
}
EOF

cat > html/index.html <<'EOF'
ok
EOF

echo "DOMAIN=${DOMAIN}" > .env
echo "BACKEND_PORT=${BACKEND_PORT}" >> .env
echo "MANAGED_BY=pnk-node" >> .env

pnk_ok "Файлы записаны"

# ── start ────────────────────────────────────────────────────────
pnk_step 6 6 "Запуск"
sleep 2
docker compose up -d
sleep 3
if docker exec cdn-nginx nginx -t 2>&1; then
  pnk_ok "nginx -t OK"
else
  pnk_err "nginx -t failed"
  docker compose logs --tail 40 || true
  exit 1
fi

ROOT_CODE="$(curl -sk "https://${DOMAIN}/" -o /dev/null -w "%{http_code}" || true)"
API_CODE="$(curl -sk "https://${DOMAIN}/api/uploadFile/" -o /dev/null -w "%{http_code}" || true)"

echo
pnk_box_top "CDN DONE" 52
pnk_box_line "${OK}${G_OK}${NC}  CDN ${TEAL_B}${DOMAIN}${NC}"
pnk_box_line "    ${MUTED}dir${NC}     ${CDN_DIR}"
pnk_box_line "    ${MUTED}/${NC}       HTTP ${ROOT_CODE}  (ожидаем 200)"
pnk_box_line "    ${MUTED}/api${NC}    HTTP ${API_CODE}  (502 норм, если xray ещё нет)"
pnk_box_line "    ${MUTED}proxy${NC}  → 127.0.0.1:${BACKEND_PORT}"
pnk_box_bottom 52
pnk_footer
