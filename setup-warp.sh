#!/usr/bin/env bash
# pnk-node — WARP-NATIVE (WireGuard + wgcf)
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

RESTORE_DNS_REQUIRED=false

restore_dns() {
  if [[ "$RESTORE_DNS_REQUIRED" == true && -f /etc/resolv.conf.backup ]]; then
    cp /etc/resolv.conf.backup /etc/resolv.conf
    RESTORE_DNS_REQUIRED=false
    pnk_ok "DNS восстановлен"
  fi
}
trap restore_dns EXIT

warp_installed() {
  command -v wgcf >/dev/null 2>&1 && [[ -f /etc/wireguard/warp.conf ]]
}

uninstall_warp() {
  pnk_info "Удаляю WARP-NATIVE..."
  if ip link show warp &>/dev/null; then
    wg-quick down warp &>/dev/null || true
  fi
  systemctl disable --now wg-quick@warp &>/dev/null || true
  rm -f /etc/wireguard/warp.conf
  rm -f /usr/local/bin/wgcf
  rm -f /etc/cron.d/warp-native
  rm -rf /opt/warp-native
  rm -f wgcf-account.toml wgcf-profile.conf 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get remove --purge -y wireguard >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true
  pnk_ok "WARP удалён"
}

install_watchdog() {
  mkdir -p /opt/warp-native/logs
  cat > /opt/warp-native/config.env <<'EOF'
HANDSHAKE_THRESHOLD=180
RESTART_COOLDOWN=120
LOG_MAX_LINES=1000
EOF

  cat > /opt/warp-native/warp-watchdog.sh <<'WATCHDOG_EOF'
#!/bin/bash
CONFIG="/opt/warp-native/config.env"
LOG="/opt/warp-native/logs/watchdog.log"
COOLDOWN_FILE="/opt/warp-native/logs/.last_restart"

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

HANDSHAKE_THRESHOLD="${HANDSHAKE_THRESHOLD:-180}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-120}"
LOG_MAX_LINES="${LOG_MAX_LINES:-1000}"

log() {
  local level="$1" message="$2" ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] [$level] $message" >> "$LOG"
}

rotate_log() {
  if [[ -f "$LOG" ]]; then
    local lines
    lines=$(wc -l < "$LOG")
    if [[ $lines -gt $LOG_MAX_LINES ]]; then
      tail -n "$LOG_MAX_LINES" "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
  fi
}

do_restart() {
  local reason="$1"
  if [[ -f "$COOLDOWN_FILE" ]]; then
    local last_restart now diff
    last_restart=$(cat "$COOLDOWN_FILE")
    now=$(date +%s)
    diff=$(( now - last_restart ))
    if [[ $diff -lt $RESTART_COOLDOWN ]]; then
      log "SKIP" "Restart skipped (cooldown: ${diff}s). Reason: $reason"
      return
    fi
  fi
  log "RESTART" "Restarting wg-quick@warp. Reason: $reason"
  systemctl restart wg-quick@warp
  local ret=$?
  date +%s > "$COOLDOWN_FILE"
  if [[ $ret -eq 0 ]]; then
    log "OK" "wg-quick@warp restarted"
  else
    log "ERROR" "restart failed (exit $ret)"
  fi
}

rotate_log

if ! systemctl is-active --quiet wg-quick@warp; then
  do_restart "systemd unit is not active"
  exit 0
fi

handshake_ts=$(wg show warp latest-handshakes 2>/dev/null | awk '{print $2}')
if [[ -z "$handshake_ts" || "$handshake_ts" -eq 0 ]]; then
  do_restart "no handshake data"
  exit 0
fi

now=$(date +%s)
age=$(( now - handshake_ts ))
if [[ $age -gt $HANDSHAKE_THRESHOLD ]]; then
  do_restart "handshake too old (${age}s > ${HANDSHAKE_THRESHOLD}s)"
  exit 0
fi

if ! ping -I warp -c 2 -W 3 1.1.1.1 &>/dev/null; then
  do_restart "ping via warp interface failed"
  exit 0
fi

log "OK" "WARP healthy (handshake: ${age}s ago)"
WATCHDOG_EOF

  chmod +x /opt/warp-native/warp-watchdog.sh
  cat > /etc/cron.d/warp-native <<'EOF'
# pnk-node WARP-NATIVE watchdog
*/10 * * * * root /opt/warp-native/warp-watchdog.sh
EOF
  chmod 644 /etc/cron.d/warp-native
  pnk_ok "Watchdog cron каждые 10 мин"
}

install_warp() {
  pnk_step 1 5 "WireGuard"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y wireguard >/dev/null
  pnk_ok "wireguard установлен"

  pnk_step 2 5 "Временный DNS"
  cp /etc/resolv.conf /etc/resolv.conf.backup
  RESTORE_DNS_REQUIRED=true
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  pnk_ok "DNS → 1.1.1.1 / 8.8.8.8"

  pnk_step 3 5 "wgcf"
  local version arch wgcf_arch url bin
  version="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+' || true)"
  if [[ -z "$version" ]]; then
    # fallback without -P (busybox/old grep)
    version="$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep tag_name | cut -d '"' -f 4 || true)"
  fi
  [[ -n "$version" ]] || { pnk_err "Не удалось получить версию wgcf"; exit 1; }

  arch="$(uname -m)"
  case "$arch" in
    x86_64) wgcf_arch="amd64" ;;
    aarch64|arm64) wgcf_arch="arm64" ;;
    armv7l) wgcf_arch="armv7" ;;
    *) wgcf_arch="amd64" ;;
  esac

  url="https://github.com/ViRb3/wgcf/releases/download/${version}/wgcf_${version#v}_linux_${wgcf_arch}"
  bin="wgcf_${version#v}_linux_${wgcf_arch}"
  pnk_info "Скачиваю wgcf ${TEAL}${version}${NC} (${wgcf_arch})..."
  curl -fsSL "$url" -o "$bin"
  chmod +x "$bin"
  mv "$bin" /usr/local/bin/wgcf
  pnk_ok "wgcf → /usr/local/bin/wgcf"

  pnk_step 4 5 "Регистрация Cloudflare WARP"
  rm -f wgcf-account.toml wgcf-profile.conf 2>/dev/null || true
  local output ret=0
  set +e
  output="$(timeout 60 bash -c 'yes | wgcf register' 2>&1)"
  ret=$?
  set -e
  if [[ ! -f wgcf-account.toml ]]; then
    pnk_warn "Первая попытка не удалась (код ${ret}), повторяю..."
    sleep 2
    timeout 60 bash -c 'yes | wgcf register' >/dev/null 2>&1 || true
  fi
  [[ -f wgcf-account.toml ]] || { pnk_err "Регистрация WARP не удалась"; echo "$output" >&2; exit 1; }

  wgcf generate >/dev/null
  local conf="wgcf-profile.conf"
  [[ -f "$conf" ]] || { pnk_err "wgcf-profile.conf не создан"; exit 1; }

  sed -i '/^DNS =/d' "$conf"
  grep -q 'Table = off' "$conf" || sed -i '/^MTU =/aTable = off' "$conf"
  grep -q 'PersistentKeepalive = 25' "$conf" || sed -i '/^Endpoint =/aPersistentKeepalive = 25' "$conf"
  # strip IPv6 addresses — IPv4-only warp iface
  sed -i 's/,\s*[0-9a-fA-F:]\+\/128//' "$conf"
  sed -i '/Address = [0-9a-fA-F:]\+\/128/d' "$conf"

  mkdir -p /etc/wireguard
  mv "$conf" /etc/wireguard/warp.conf
  pnk_ok "Конфиг: Table=off, Keepalive=25, IPv4-only"

  pnk_step 5 5 "Интерфейс warp"
  systemctl enable wg-quick@warp >/dev/null 2>&1 || true
  systemctl restart wg-quick@warp

  local i handshake_ts=0
  for i in $(seq 1 10); do
    handshake_ts="$(wg show warp latest-handshakes 2>/dev/null | awk '{print $2}')"
    if [[ -n "$handshake_ts" && "$handshake_ts" -gt 0 ]]; then
      pnk_ok "Handshake OK ($(( $(date +%s) - handshake_ts ))s ago)"
      break
    fi
    sleep 1
  done

  local curl_result
  curl_result="$(curl -s --interface warp --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep '^warp=' | cut -d= -f2 || true)"
  if [[ "$curl_result" == "on" ]]; then
    pnk_ok "Cloudflare подтвердил warp=on"
  else
    pnk_warn "warp=on не подтверждён (может подняться чуть позже)"
  fi

  install_watchdog
  restore_dns

  echo
  pnk_box_top "WARP-NATIVE" 52
  pnk_box_line "iface:   warp  (Table = off — без default route)"
  pnk_box_line "status:  systemctl status wg-quick@warp"
  pnk_box_line "info:    wg show warp"
  pnk_box_line "лог:     tail -f /opt/warp-native/logs/watchdog.log"
  pnk_box_line "Xray:    outbound через интерфейс warp"
  pnk_box_bottom 52
}

# ── main ─────────────────────────────────────────────────────────
pnk_clear
pnk_banner "WARP-NATIVE"
pnk_section "Cloudflare WARP (WireGuard)"

echo
pnk_menu_item "1" "Установить / переустановить" "wgcf + watchdog"
pnk_menu_item "2" "Удалить WARP"
pnk_menu_item "0" "Отмена"
echo
pnk_ask "Выбор [0-2]" CHOICE "1"

case "$CHOICE" in
  0|q|Q) pnk_muted "Отменено"; exit 0 ;;
  2)
    if warp_installed || systemctl list-unit-files 2>/dev/null | grep -q 'wg-quick@warp'; then
      uninstall_warp
    else
      pnk_warn "WARP не найден"
    fi
    ;;
  *)
    if warp_installed; then
      pnk_warn "WARP уже установлен"
      if ! pnk_confirm "Переустановить?" "N"; then
        pnk_footer
        exit 0
      fi
      uninstall_warp
      echo
    fi
    install_warp
    ;;
esac

pnk_footer
