#!/usr/bin/env bash
# pnk-node — Reality self-steal (Caddy or Nginx)
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

SITE_DIR="/var/www/site"
MONITOR_PORT_DEFAULT="8443"

deploy_fake_site() {
  mkdir -p "${SITE_DIR}"
  local meta_id class_id comment_id meta_name
  meta_id="$(openssl rand -hex 16 2>/dev/null || echo "a1b2c3d4e5f67890")"
  class_id="$(openssl rand -hex 8 2>/dev/null || echo "deadbeef")"
  comment_id="$(openssl rand -hex 12 2>/dev/null || echo "cafebabe0000")"
  local names=("render-id" "view-id" "page-id" "config-id")
  meta_name="${names[$((RANDOM % ${#names[@]}))]}"

  cat > "${SITE_DIR}/index.html" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="${meta_name}" content="${meta_id}">
  <!-- ${comment_id} -->
  <title>503 — Service Unavailable</title>
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0; min-height: 100vh; display: grid; place-items: center;
      font-family: ui-sans-serif, system-ui, sans-serif;
      background: #0f172a; color: #e2e8f0;
    }
    .box.${class_id} { text-align: center; padding: 2rem; }
    h1 { font-size: 3rem; margin: 0 0 .5rem; letter-spacing: .04em; }
    p { margin: 0; opacity: .65; }
  </style>
</head>
<body>
  <div class="box ${class_id}">
    <h1>503</h1>
    <p>Критическая нагрузка системы. Попробуйте позже.</p>
  </div>
</body>
</html>
EOF
  chmod -R a+rX "${SITE_DIR}" 2>/dev/null || true
  pnk_ok "Фейковый сайт → ${SITE_DIR}"
}

stop_peer_webserver() {
  local keep="$1"
  if [[ "$keep" == "caddy" ]]; then
    if command -v nginx >/dev/null 2>&1; then
      pnk_warn "Останавливаю Nginx (конфликт с Caddy)"
      systemctl stop nginx 2>/dev/null || true
      systemctl disable nginx 2>/dev/null || true
    fi
  else
    if command -v caddy >/dev/null 2>&1; then
      pnk_warn "Останавливаю Caddy (конфликт с Nginx)"
      systemctl stop caddy 2>/dev/null || true
      systemctl disable caddy 2>/dev/null || true
    fi
  fi
}

install_caddy_pkg() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y >/dev/null
  apt-get install -y caddy >/dev/null
}

write_caddyfile() {
  local domain="$1" port="$2"
  cat > /etc/caddy/Caddyfile <<EOF
${domain}:${port} {
    @local {
        remote_ip 127.0.0.1 ::1
    }

    handle @local {
        root * ${SITE_DIR}
        try_files {path} /index.html
        file_server
    }

    handle {
        abort
    }
}
EOF
}

install_nginx_pkg() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y nginx certbot >/dev/null
}

write_nginx_main() {
  cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 65535;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent"';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    client_body_buffer_size 16k;
    client_header_buffer_size 1k;
    client_max_body_size 8m;
    large_client_header_buffers 4 8k;
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;
    include /etc/nginx/conf.d/*.conf;
}
EOF
}

write_nginx_selfsteal() {
  local domain="$1" port="$2" cert_domain="$3" use_pp="$4"
  local listen_main="ssl http2"
  local listen_def="ssl"
  local pp_block=""
  if [[ "$use_pp" =~ ^[Yy]$ ]]; then
    listen_main="ssl proxy_protocol http2"
    listen_def="ssl proxy_protocol"
    pp_block=$'    set_real_ip_from 127.0.0.1;\n    real_ip_header proxy_protocol;\n'
  fi

  cat > /etc/nginx/conf.d/selfsteal.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:${port} ${listen_main};
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${cert_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${cert_domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;
${pp_block}
    root ${SITE_DIR};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}

server {
    listen 127.0.0.1:${port} ${listen_def} default_server;
    server_name _;
    ssl_certificate     /etc/letsencrypt/live/${cert_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${cert_domain}/privkey.pem;
    return 204;
}
EOF
}

issue_cert() {
  local domain="$1" method="$2"
  local cert_domain="$domain"
  case "$method" in
    1)
      pnk_ask "Cloudflare API token (или Global API Key)" CF_API_KEY
      pnk_ask "Cloudflare email (для Global Key; Enter если token)" CF_EMAIL ""
      mkdir -p /root/.secrets
      if [[ "$CF_API_KEY" =~ [A-Z] ]]; then
        cat > /root/.secrets/cloudflare.ini <<EOF
dns_cloudflare_api_token = ${CF_API_KEY}
EOF
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
        || { pnk_err "Не удалось получить сертификат (Cloudflare)"; exit 1; }
      ;;
    2)
      pnk_ask "Email для Let's Encrypt" LE_EMAIL
      systemctl stop nginx 2>/dev/null || true
      certbot certonly --standalone -d "$domain" \
        --non-interactive --agree-tos -m "${LE_EMAIL}" \
        || { pnk_err "Не удалось получить сертификат (HTTP-01)"; exit 1; }
      ;;
    3)
      pnk_ask "Gcore API token" GCORE_API_KEY
      pnk_ask "Email для Let's Encrypt" LE_EMAIL
      apt-get install -y python3-pip >/dev/null
      pip3 install --break-system-packages certbot-dns-gcore 2>/dev/null \
        || pip3 install certbot-dns-gcore >/dev/null
      mkdir -p /root/.secrets
      cat > /root/.secrets/gcore.ini <<EOF
dns_gcore_api_token = ${GCORE_API_KEY}
EOF
      chmod 600 /root/.secrets/gcore.ini
      local base
      base="$(echo "$domain" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')"
      cert_domain="$base"
      certbot certonly --authenticator dns-gcore \
        --dns-gcore-credentials /root/.secrets/gcore.ini \
        -d "$base" -d "*.${base}" \
        --non-interactive --agree-tos -m "${LE_EMAIL}" \
        || { pnk_err "Не удалось получить сертификат (Gcore)"; exit 1; }
      ;;
    *)
      pnk_warn "Пропуск выпуска сертификата — нужны существующие LE-сертификаты"
      ;;
  esac
  REPLY_CERT_DOMAIN="$cert_domain"
}

setup_renewal_cron() {
  local method="$1"
  local cron_file="/etc/cron.d/pnk-node-certbot"
  if [[ "$method" == "2" ]]; then
    cat > "$cron_file" <<'EOF'
0 5 * * 0 root systemctl stop nginx; certbot renew --quiet; systemctl start nginx
EOF
  else
    cat > "$cron_file" <<'EOF'
0 5 * * 0 root certbot renew --quiet && systemctl reload nginx
EOF
  fi
  chmod 644 "$cron_file"
}

# ── main ─────────────────────────────────────────────────────────
pnk_clear
pnk_banner "self-steal · Reality dest"
pnk_section "Веб-сервер для Reality dest (self-steal)"

echo
pnk_menu_item "1" "Caddy"  "auto HTTPS, abort non-local"
pnk_menu_item "2" "Nginx"  "LE cert + loopback TLS"
pnk_menu_item "0" "Отмена"
echo
pnk_ask "Выбор [0-2]" WS_CHOICE "1"

case "$WS_CHOICE" in
  0|q|Q) pnk_muted "Отменено"; exit 0 ;;
  2) WEBSERVER="nginx" ;;
  *) WEBSERVER="caddy" ;;
esac

pnk_ask "Домен ноды (A/AAAA → этот сервер)" DOMAIN
[[ -n "$DOMAIN" ]] || { pnk_err "Домен обязателен"; exit 1; }

pnk_ask "Порт self-steal (MONITOR_PORT)" MONITOR_PORT "$MONITOR_PORT_DEFAULT"
MONITOR_PORT="${MONITOR_PORT:-$MONITOR_PORT_DEFAULT}"

if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^127\\.0\\.0\\.1:${MONITOR_PORT}$|^0\\.0\\.0\\.0:${MONITOR_PORT}$|:${MONITOR_PORT}$)"; then
  pnk_warn "Порт ${MONITOR_PORT} уже слушается на хосте"
  if ! pnk_confirm "Продолжить всё равно?" "N"; then
    exit 1
  fi
fi

pnk_info "Если нода публикует ${MONITOR_PORT} наружу (Xray) — возможен конфликт с Caddy."
pnk_muted "Nginx слушает только 127.0.0.1 — с публичным bind обычно ок."

USE_PROXY_PROTOCOL="n"
CERT_METHOD="2"
if [[ "$WEBSERVER" == "nginx" ]]; then
  echo
  pnk_section "Nginx · сертификат"
  pnk_menu_item "1" "Cloudflare DNS-01" "wildcard"
  pnk_menu_item "2" "HTTP-01 standalone" "нужен :80"
  pnk_menu_item "3" "Gcore DNS-01" "wildcard"
  pnk_menu_item "4" "Уже есть certbot" "не выпускать"
  echo
  pnk_ask "Метод [1-4]" CERT_METHOD "2"
  if pnk_confirm "Включить proxy_protocol (xver=1)?" "N"; then
    USE_PROXY_PROTOCOL="y"
  fi
fi

pnk_step 1 3 "Пакеты + сайт"
deploy_fake_site
stop_peer_webserver "$WEBSERVER"

if [[ "$WEBSERVER" == "caddy" ]]; then
  pnk_step 2 3 "Caddy"
  if ! command -v caddy >/dev/null 2>&1; then
    pnk_info "Ставлю Caddy из Cloudsmith..."
    install_caddy_pkg
  else
    pnk_ok "Caddy уже установлен"
  fi
  write_caddyfile "$DOMAIN" "$MONITOR_PORT"
  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl restart caddy
  pnk_ok "Caddy слушает ${DOMAIN}:${MONITOR_PORT}"
else
  pnk_step 2 3 "Nginx + certbot"
  install_nginx_pkg
  write_nginx_main
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  issue_cert "$DOMAIN" "$CERT_METHOD"
  CERT_DOMAIN="${REPLY_CERT_DOMAIN:-$DOMAIN}"
  write_nginx_selfsteal "$DOMAIN" "$MONITOR_PORT" "$CERT_DOMAIN" "$USE_PROXY_PROTOCOL"
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl restart nginx
  setup_renewal_cron "$CERT_METHOD"
  pnk_ok "Nginx self-steal на 127.0.0.1:${MONITOR_PORT}"
fi

pnk_step 3 3 "Подсказки для Reality"
echo
pnk_box_top "REALITY DEST" 52
if [[ "$WEBSERVER" == "caddy" ]]; then
  pnk_box_line "dest / target: 127.0.0.1:${MONITOR_PORT}"
  pnk_box_line "serverNames:   ${DOMAIN}"
  pnk_box_line "xver:          0"
else
  pnk_box_line "target:  127.0.0.1:${MONITOR_PORT}"
  pnk_box_line "serverNames: ${DOMAIN}"
  if [[ "$USE_PROXY_PROTOCOL" =~ ^[Yy]$ ]]; then
    pnk_box_line "xver:    1  (proxy_protocol)"
  else
    pnk_box_line "xver:    0"
  fi
fi
pnk_box_bottom 52
pnk_footer
