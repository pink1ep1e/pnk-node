#!/usr/bin/env bash
# pnk-node — eGames-style node: remnanode (host) + Nginx/Caddy self-steal via unix socket
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

OPT_DIR="/opt/remnanode"
SITE_DIR="/var/www/html"
SOCKET_PATH="/dev/shm/nginx.sock"
NODE_PORT="2222"

sanitize_secret_key() {
  local k="$1"
  k="$(echo "$k" | sed -E 's/^[[:space:]]*SSL_CERT[[:space:]]*=[[:space:]]*//')"
  k="$(echo "$k" | sed -E 's/^[[:space:]]*SECRET_KEY[[:space:]]*=[[:space:]]*//')"
  k="$(echo "$k" | sed -E 's/^[[:space:]]*["'\'']?//' | sed -E 's/["'\'']?[[:space:]]*$//')"
  k="$(echo "$k" | sed -E 's/^[[:space:]]+//' | sed -E 's/[[:space:]]+$//')"
  echo "$k"
}

read_secret_key() {
  local line buffer=""
  pnk_muted "Вставьте SECRET_KEY (пустая строка — конец ввода)"
  pnk_prompt ""
  while IFS= read -r line </dev/tty; do
    if [[ -z "$line" ]]; then
      [[ -n "$buffer" ]] && break
      continue
    fi
    if [[ -n "$buffer" ]]; then
      buffer+=$'\n'
    fi
    buffer+="$line"
  done
  SECRET_KEY="$(sanitize_secret_key "$buffer")"
}

deploy_site() {
  mkdir -p "${SITE_DIR}"
  local meta_id class_id
  meta_id="$(openssl rand -hex 16 2>/dev/null || echo "a1b2c3d4e5f67890")"
  class_id="$(openssl rand -hex 8 2>/dev/null || echo "deadbeef")"
  cat > "${SITE_DIR}/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="render-id" content="${meta_id}">
  <meta name="robots" content="noindex, nofollow">
  <title>Welcome</title>
  <style>
    body { margin: 0; min-height: 100vh; display: grid; place-items: center;
      font-family: system-ui, sans-serif; background: #f8fafc; color: #0f172a; }
    .box.${class_id} { text-align: center; padding: 2rem; }
    h1 { font-size: 1.5rem; margin: 0 0 .5rem; }
    p { margin: 0; opacity: .6; }
  </style>
</head>
<body>
  <div class="box ${class_id}">
    <h1>Service</h1>
    <p>Everything is fine.</p>
  </div>
</body>
</html>
EOF
  chmod -R a+rX "${SITE_DIR}" 2>/dev/null || true
}

ensure_docker() {
  if ! command -v docker &>/dev/null; then
    pnk_info "Ставлю Docker..."
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
  if ! docker compose version >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y docker-compose-v2 >/dev/null 2>&1 || true
  fi
}

stop_conflicts() {
  systemctl stop nginx 2>/dev/null || true
  systemctl disable nginx 2>/dev/null || true
  systemctl stop caddy 2>/dev/null || true
  docker rm -f remnawave-nginx caddy-remnawave cdn-nginx 2>/dev/null || true
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
    pnk_warn "Контейнер remnanode уже есть"
    if pnk_confirm "Остановить и переустановить?" "Y"; then
      docker rm -f remnanode 2>/dev/null || true
    else
      pnk_err "Отменено"
      exit 1
    fi
  fi
}

ensure_ufw() {
  local panel_ip="$1"
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v ufw &>/dev/null; then
    apt-get update -y >/dev/null
    apt-get install -y ufw >/dev/null
  fi
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    local ssh_port
    ssh_port="$(ss -tnlp 2>/dev/null | grep -i sshd | awk '{print $4}' | sed 's/.*://g' | sort -u | head -n1 || true)"
    ssh_port="${ssh_port:-22}"
    ufw allow "${ssh_port}/tcp" comment 'SSH Port' >/dev/null 2>&1 || true
    ufw --force enable >/dev/null
  fi
  ufw allow from "${panel_ip}" to any port "${NODE_PORT}" proto tcp \
    comment "pnk-node remnanode api from panel" >/dev/null 2>&1 || true
  ufw allow 80/tcp comment 'pnk-node HTTP' >/dev/null 2>&1 || true
  ufw allow 443/tcp comment 'pnk-node HTTPS/Reality' >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
  pnk_ok "UFW: :${NODE_PORT} ← ${panel_ip}, 80/443 открыты"
}

issue_cert_nginx() {
  local domain="$1" method="$2"
  local cert_domain="$domain"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y certbot >/dev/null
  case "$method" in
    1)
      pnk_ask "Cloudflare API token (или Global API Key)" CF_API_KEY
      pnk_ask "Cloudflare email (для Global Key; Enter если token)" CF_EMAIL ""
      mkdir -p /root/.secrets
      if [[ "$CF_API_KEY" =~ [A-Z] ]]; then
        printf 'dns_cloudflare_api_token = %s\n' "$CF_API_KEY" > /root/.secrets/cloudflare.ini
      else
        [[ -n "$CF_EMAIL" ]] || { pnk_err "Нужен email для Global API Key"; exit 1; }
        cat > /root/.secrets/cloudflare.ini <<EOF
dns_cloudflare_email = ${CF_EMAIL}
dns_cloudflare_api_key = ${CF_API_KEY}
EOF
      fi
      chmod 600 /root/.secrets/cloudflare.ini
      apt-get install -y python3-certbot-dns-cloudflare >/dev/null
      local base
      base="$(echo "$domain" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')"
      cert_domain="$base"
      certbot certonly --dns-cloudflare \
        --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
        -d "$base" -d "*.${base}" \
        --key-type ecdsa --elliptic-curve secp384r1 \
        --non-interactive --agree-tos --register-unsafely-without-email \
        || { pnk_err "Сертификат Cloudflare не выдан"; exit 1; }
      ;;
    2)
      pnk_ask "Email для Let's Encrypt" LE_EMAIL "admin@${domain}"
      certbot certonly --standalone -d "$domain" \
        --non-interactive --agree-tos -m "${LE_EMAIL}" \
        --preferred-challenges http \
        || { pnk_err "Сертификат HTTP-01 не выдан"; exit 1; }
      ;;
    *)
      pnk_warn "Используем существующий certbot lineage для ${domain}"
      ;;
  esac
  if [[ ! -f "/etc/letsencrypt/live/${cert_domain}/fullchain.pem" ]]; then
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
      cert_domain="$domain"
    else
      pnk_err "Нет сертификата в /etc/letsencrypt/live/${cert_domain}"
      exit 1
    fi
  fi
  REPLY_CERT_DOMAIN="$cert_domain"
}

write_nginx_conf() {
  local domain="$1" cert_domain="$2"
  cat > "${OPT_DIR}/nginx.conf" <<EOF
server_names_hash_bucket_size 64;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305';
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name ${domain};
    listen unix:${SOCKET_PATH} ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/letsencrypt/live/${cert_domain}/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/${cert_domain}/privkey.pem";
    ssl_trusted_certificate "/etc/letsencrypt/live/${cert_domain}/fullchain.pem";

    root ${SITE_DIR};
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    listen unix:${SOCKET_PATH} ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOF
}

write_caddyfile() {
  cat > "${OPT_DIR}/Caddyfile" <<'EOF'
{
    admin off
    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
    auto_https disable_redirects
}

http://{$SELF_STEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://{$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{$SELF_STEAL_DOMAIN} {
    bind unix/{$CADDY_SOCKET_PATH}
    root * /var/www/html
    try_files {path} /index.html
    file_server
}

:80 {
    bind 0.0.0.0
    respond 204
}
EOF
}

write_compose_nginx() {
  local version="$1" secret_escaped="$2"
  cat > "${OPT_DIR}/docker-compose.yml" <<EOF
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "5"

services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /dev/shm:/dev/shm:rw
      - ${SITE_DIR}:${SITE_DIR}:ro
    command: sh -c 'rm -f ${SOCKET_PATH} && exec nginx -g "daemon off;"'

  remnanode:
    image: remnawave/node:${version}
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${secret_escaped}
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
EOF
}

write_compose_caddy() {
  local version="$1" secret_escaped="$2" domain="$3"
  cat > "${OPT_DIR}/docker-compose.yml" <<EOF
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "5"

services:
  caddy:
    image: caddy:2.11.2
    container_name: caddy-remnawave
    hostname: caddy-remnawave
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ${SITE_DIR}:${SITE_DIR}:ro
      - /dev/shm:/dev/shm:rw
      - caddy_data:/data
    command: sh -c 'rm -f ${SOCKET_PATH} && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    environment:
      - CADDY_SOCKET_PATH=${SOCKET_PATH}
      - SELF_STEAL_DOMAIN=${domain}
    healthcheck:
      test: ["CMD", "test", "-S", "${SOCKET_PATH}"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 5s

  remnanode:
    image: remnawave/node:${version}
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${secret_escaped}
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode

volumes:
  caddy_data:
    name: caddy_data
    driver: local
EOF
}

# ── main ─────────────────────────────────────────────────────────
pnk_clear
pnk_banner "eGames-style · node + selfsteal"
pnk_section "Установка remnanode (host) + self-steal"

if [[ -d "$OPT_DIR" ]]; then
  pnk_warn "${OPT_DIR} уже существует"
  if ! pnk_confirm "Переустановить поверх?" "N"; then
    exit 0
  fi
fi

echo
pnk_menu_item "1" "Nginx" "LE cert + unix socket"
pnk_menu_item "2" "Caddy" "auto HTTPS + unix socket"
echo
pnk_ask "Веб-сервер [1-2]" WS_CHOICE "1"
case "$WS_CHOICE" in
  2) WEBSERVER="caddy" ;;
  *) WEBSERVER="nginx" ;;
esac

echo
pnk_menu_item "1" "latest" "рекомендуется"
pnk_menu_item "2" "2.8.0" "legacy"
pnk_menu_item "3" "Вручную" "tag / semver"
echo
pnk_ask "Версия образа ноды [1-3]" VER_CHOICE "1"
case "$VER_CHOICE" in
  2) NODE_VERSION="2.8.0" ;;
  3)
    pnk_ask "Тег образа (например 2.8.0)" NODE_VERSION
    [[ -n "$NODE_VERSION" ]] || { pnk_err "Версия пустая"; exit 1; }
    ;;
  *) NODE_VERSION="latest" ;;
esac
pnk_ok "image remnawave/node:${TEAL}${NODE_VERSION}${NC}"

pnk_ask "Selfsteal-домен (из карточки ноды в панели)" SELFSTEAL_DOMAIN
[[ -n "$SELFSTEAL_DOMAIN" ]] || { pnk_err "Домен обязателен"; exit 1; }

while true; do
  pnk_ask "IP панели Remnawave" PANEL_IP
  if [[ "$PANEL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    break
  fi
  pnk_err "Нужен IPv4"
done

read_secret_key
[[ -n "$SECRET_KEY" ]] || { pnk_err "SECRET_KEY пустой"; exit 1; }
pnk_ok "SECRET_KEY принят"

CERT_METHOD="2"
CERT_DOMAIN="$SELFSTEAL_DOMAIN"
if [[ "$WEBSERVER" == "nginx" ]]; then
  echo
  pnk_section "Сертификат (Nginx)"
  pnk_menu_item "1" "Cloudflare DNS-01" "wildcard"
  pnk_menu_item "2" "HTTP-01 standalone" "нужен :80"
  pnk_menu_item "3" "Уже есть certbot" "не выпускать"
  echo
  pnk_ask "Метод [1-3]" CERT_METHOD "2"
fi

pnk_step 1 6 "Docker + конфликты"
ensure_docker
stop_conflicts
mkdir -p /var/log/remnanode "$OPT_DIR"
deploy_site
pnk_ok "Сайт → ${SITE_DIR}"

# escape for YAML single-line env (quote)
SECRET_ESC="$(printf '%s' "$SECRET_KEY" | sed 's/"/\\"/g')"
SECRET_ESC="\"${SECRET_ESC}\""

pnk_step 2 6 "UFW"
ensure_ufw "$PANEL_IP"

if [[ "$WEBSERVER" == "nginx" ]]; then
  pnk_step 3 6 "Let's Encrypt"
  issue_cert_nginx "$SELFSTEAL_DOMAIN" "$CERT_METHOD"
  CERT_DOMAIN="${REPLY_CERT_DOMAIN:-$SELFSTEAL_DOMAIN}"
  pnk_ok "cert ${CERT_DOMAIN}"

  pnk_step 4 6 "Конфиги"
  write_nginx_conf "$SELFSTEAL_DOMAIN" "$CERT_DOMAIN"
  write_compose_nginx "$NODE_VERSION" "$SECRET_ESC"
else
  pnk_step 3 6 "Caddy ACME"
  pnk_muted "Сертификат выпустит Caddy автоматически"
  pnk_step 4 6 "Конфиги"
  write_caddyfile
  write_compose_caddy "$NODE_VERSION" "$SECRET_ESC" "$SELFSTEAL_DOMAIN"
fi

cat > "${OPT_DIR}/.env" <<EOF
COMPOSE_PROJECT_NAME=remnanode
NODE_NAME=remnanode
NODE_PORT=${NODE_PORT}
NODE_VERSION=${NODE_VERSION}
SELFSTEAL_DOMAIN=${SELFSTEAL_DOMAIN}
PANEL_IP=${PANEL_IP}
WEBSERVER=${WEBSERVER}
CERT_DOMAIN=${CERT_DOMAIN}
MANAGED_BY=pnk-node-egames
INSTALL_MODE=egames-host
EOF

pnk_step 5 6 "Запуск"
cd "$OPT_DIR"
docker compose up -d
sleep 3

if ! docker ps --format '{{.Names}}' | grep -qx remnanode; then
  pnk_err "Контейнер remnanode не запустился"
  docker compose logs --tail 50 || true
  exit 1
fi
pnk_ok "remnanode online"

pnk_step 6 6 "Проверка https://${SELFSTEAL_DOMAIN}"
ok_check=false
for attempt in 1 2 3 4 5; do
  pnk_muted "попытка ${attempt}/5..."
  if curl -sk --fail --max-time 12 "https://${SELFSTEAL_DOMAIN}" 2>/dev/null | grep -qi "html\|Service\|Welcome\|fine"; then
    ok_check=true
    break
  fi
  sleep 8
done
if [[ "$ok_check" == true ]]; then
  pnk_ok "Selfsteal отвечает"
else
  pnk_warn "HTTPS пока не отвечает — проверь DNS/Reality dest и логи docker compose"
fi

echo
pnk_box_top "EGAMES NODE" 52
pnk_box_line "${OK}${G_OK}${NC}  remnanode ${MUTED}+${NC} ${WEBSERVER}"
pnk_box_line "    ${MUTED}dir${NC}     ${OPT_DIR}"
pnk_box_line "    ${MUTED}image${NC}   remnawave/node:${NODE_VERSION}"
pnk_box_line "    ${MUTED}domain${NC}  ${SELFSTEAL_DOMAIN}"
pnk_box_line "    ${MUTED}api${NC}     :${NODE_PORT} ← ${PANEL_IP}"
pnk_box_line "    ${MUTED}sock${NC}    ${SOCKET_PATH}"
pnk_box_bottom 52
pnk_muted "В панели Reality dest = selfsteal-домен, xver=1 (proxy_protocol)"
pnk_footer
