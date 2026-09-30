#!/usr/bin/env bash
# pnk-node — enable TCP BBR congestion control
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

pnk_clear
pnk_banner "BBR · tcp congestion"
pnk_section "TCP BBR"

CURRENT="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
pnk_kv "сейчас" "$CURRENT"

if [[ "$CURRENT" == "bbr" ]]; then
  pnk_ok "BBR уже активен"
  if ! pnk_confirm "Перезаписать sysctl-настройки?" "N"; then
    pnk_footer
    exit 0
  fi
fi

if ! pnk_confirm "Включить BBR (fq + bbr)?" "Y"; then
  pnk_muted "Отменено"
  exit 0
fi

modprobe tcp_bbr 2>/dev/null || true

SYSCTL_FILE="/etc/sysctl.d/99-pnk-bbr.conf"
cat > "${SYSCTL_FILE}" <<'EOF'
# Managed by pnk-node
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

# keep /etc/sysctl.conf tidy: drop duplicate lines if we previously appended there
if [[ -f /etc/sysctl.conf ]]; then
  sed -i '/^net\.core\.default_qdisc=fq$/d' /etc/sysctl.conf 2>/dev/null || true
  sed -i '/^net\.ipv4\.tcp_congestion_control=bbr$/d' /etc/sysctl.conf 2>/dev/null || true
fi

sysctl -p "${SYSCTL_FILE}" >/dev/null

NEW="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
if [[ "$NEW" == "bbr" ]]; then
  pnk_ok "BBR включён (${TEAL}${NEW}${NC})"
  pnk_kv "qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  pnk_kv "file" "${SYSCTL_FILE}"
else
  pnk_err "Не удалось активировать BBR (сейчас: ${NEW}). Ядро без CONFIG_TCP_CONGESTION_BBR?"
  exit 1
fi

pnk_footer
