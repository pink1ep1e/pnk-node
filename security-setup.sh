#!/usr/bin/env bash
# pnk-node — UFW + optional ICMP block
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/common.sh"
else
  echo "Запускай из клона репозитория или через install.sh + PNK_NODE_RAW"; exit 1
fi
pnk_load_ui "${SCRIPT_DIR}"

pnk_clear
pnk_banner "security hardening"
pnk_require_root

if ! command -v ufw &>/dev/null; then
  if command -v apt-get &>/dev/null; then
    pnk_info "Ставлю ufw..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y ufw >/dev/null
  else
    pnk_err "ufw не найден"
    exit 1
  fi
fi

# detect node port from first known install
NODE_PORT=""
for d in /opt/pnknode /opt/remnanode; do
  if [[ -f "$d/.env" ]]; then
    NODE_PORT="$(grep -E '^(APP_PORT|NODE_PORT)=' "$d/.env" | head -1 | cut -d= -f2- || true)"
    [[ -n "$NODE_PORT" ]] && break
  fi
done
if [[ -z "$NODE_PORT" ]]; then
  pnk_ask "Порт ноды (API)" NODE_PORT "2222"
fi
pnk_kv "node port" "$NODE_PORT"

ufw --force enable >/dev/null
pnk_ok "UFW включён"

if pnk_confirm "Запретить ICMP ping? (перезапишет /etc/ufw/before.rules)" "N"; then
  pnk_info "Блокирую echo-request..."
  cat > /etc/ufw/before.rules <<'EOF'
#
# rules.before — managed by pnk-node security-setup
#
*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]
:ufw-not-local - [0:0]
-A ufw-before-input -i lo -j ACCEPT
-A ufw-before-output -o lo -j ACCEPT
-A ufw-before-input -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-output -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A ufw-before-input -m conntrack --ctstate INVALID -j ufw-logging-deny
-A ufw-before-input -m conntrack --ctstate INVALID -j DROP
-A ufw-before-input -p icmp --icmp-type destination-unreachable -j DROP
-A ufw-before-input -p icmp --icmp-type time-exceeded -j DROP
-A ufw-before-input -p icmp --icmp-type parameter-problem -j DROP
-A ufw-before-input -p icmp --icmp-type echo-request -j DROP
-A ufw-before-input -p icmp --icmp-type source-quench -j DROP
-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j DROP
-A ufw-before-forward -p icmp --icmp-type time-exceeded -j DROP
-A ufw-before-forward -p icmp --icmp-type parameter-problem -j DROP
-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP
-A ufw-before-input -p udp --sport 67 --dport 68 -j ACCEPT
-A ufw-before-input -j ufw-not-local
-A ufw-not-local -m addrtype --dst-type LOCAL -j RETURN
-A ufw-not-local -m addrtype --dst-type MULTICAST -j RETURN
-A ufw-not-local -m addrtype --dst-type BROADCAST -j RETURN
-A ufw-not-local -m limit --limit 3/min --limit-burst 10 -j ufw-logging-deny
-A ufw-not-local -j DROP
-A ufw-before-input -p udp -d 224.0.0.251 --dport 5353 -j ACCEPT
-A ufw-before-input -p udp -d 239.255.255.250 --dport 1900 -j ACCEPT
COMMIT
EOF
  ufw reload >/dev/null
  pnk_ok "Ping заблокирован"
fi

pnk_section "Базовые порты"
SSH_PORT="$(ss -tnlp 2>/dev/null | grep -i sshd | awk '{print $4}' | sed 's/.*://g' | sort -u | head -n1 || true)"
SSH_PORT="${SSH_PORT:-22}"

ufw allow "${SSH_PORT}/tcp" comment 'SSH Port' >/dev/null 2>&1 || true
pnk_ok "SSH :${SSH_PORT}"

ufw allow "${NODE_PORT}/tcp" comment 'pnk-node API' >/dev/null 2>&1 || true
pnk_ok "Node API :${NODE_PORT}"

ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1 || true
ufw allow 8443/tcp comment 'HTTPS alt' >/dev/null 2>&1 || true
ufw allow 4443/tcp comment 'Xray alt' >/dev/null 2>&1 || true
pnk_ok "443 / 8443 / 4443"

echo
pnk_box_top "SECURE" 52
pnk_box_line "${OK}${G_OK}${NC}  UFW active"
pnk_box_line "    SSH   ${SSH_PORT}"
pnk_box_line "    Node  ${NODE_PORT}"
pnk_box_line "    TLS   443, 8443, 4443"
pnk_box_bottom 52
pnk_footer
