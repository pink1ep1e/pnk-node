#!/usr/bin/env bash
# pnk-node — remove Remnawave Node install
# Не используем set -e: удаление должно дочищать даже при частичных ошибках

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/common.sh"
else
  echo "Запускай из клона репозитория или через install.sh + PNK_NODE_RAW"; exit 1
fi
pnk_load_ui "${SCRIPT_DIR}"

pnk_clear
pnk_banner "removal wizard"
pnk_require_root

if ! command -v docker &>/dev/null; then
  pnk_muted "Docker не установлен — удалять нечего"
  exit 0
fi

mapfile -t NODES < <(pnk_list_nodes)
if [[ "${#NODES[@]}" -eq 0 ]]; then
  pnk_warn "Ноды не найдены в /opt/pnknode* и /opt/remnanode*"
  exit 0
fi

pnk_section "Найденные ноды"
for i in "${!NODES[@]}"; do
  NODE_DIR="${NODES[$i]}"
  NODE_NAME="$(basename "$NODE_DIR")"
  if docker ps -a --format '{{.Names}}' | grep -qx "$NODE_NAME"; then
    STATUS="${OK}container${NC}"
  else
    STATUS="${MUTED}no container${NC}"
  fi
  printf "  ${TEAL}${BOLD}[%d]${NC}  %-16s  %b\n" "$((i + 1))" "$NODE_NAME" "$STATUS"
done
echo

pnk_ask "Выберите ноду [1-${#NODES[@]}]" CHOICE
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#NODES[@]} )); then
  pnk_err "Неверный выбор"
  exit 1
fi

TARGET_DIR="${NODES[$((CHOICE - 1))]}"
NODE_NAME="$(basename "$TARGET_DIR")"

USE_CUSTOM_NETWORK="false"
NETWORK_NAME="" NETWORK_SUBNET=""
SELECTED_IFACE="" BIND_IP="" NODE_PORT=""
XRAY_PORT_HTTPS="8443" XRAY_PORT_ALT="4443"
HOST_RULE_PRIORITY="" SUBNET_RULE_PRIORITY=""
DOCKER_NET_NAME="" DOCKER_NET_SUBNET="" DOCKER_BRIDGE_IFACE=""
SYSCTL_FILE="" NET_SCRIPT="" NET_UNIT=""
ROUTING_TABLE_ID="" ROUTING_RULE_PRIORITY="" ROUTING_TABLE_NAME=""

env_get() {
  local key="$1" file="$2" def="${3:-}"
  local v
  v="$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  echo "${v:-$def}"
}

if [[ -f "$TARGET_DIR/.env" ]]; then
  USE_CUSTOM_NETWORK="$(env_get USE_CUSTOM_NETWORK "$TARGET_DIR/.env" false)"
  BIND_IP="$(env_get BIND_IP "$TARGET_DIR/.env")"
  SELECTED_IFACE="$(env_get SELECTED_IFACE "$TARGET_DIR/.env")"
  NODE_PORT="$(env_get NODE_PORT "$TARGET_DIR/.env")"
  XRAY_PORT_HTTPS="$(env_get XRAY_PORT_HTTPS "$TARGET_DIR/.env" 8443)"
  XRAY_PORT_ALT="$(env_get XRAY_PORT_ALT "$TARGET_DIR/.env" 4443)"
  HOST_RULE_PRIORITY="$(env_get HOST_RULE_PRIORITY "$TARGET_DIR/.env")"
  SUBNET_RULE_PRIORITY="$(env_get SUBNET_RULE_PRIORITY "$TARGET_DIR/.env")"
  DOCKER_NET_NAME="$(env_get DOCKER_NET_NAME "$TARGET_DIR/.env")"
  DOCKER_NET_SUBNET="$(env_get DOCKER_NET_SUBNET "$TARGET_DIR/.env")"
  DOCKER_BRIDGE_IFACE="$(env_get DOCKER_BRIDGE_IFACE "$TARGET_DIR/.env")"
  SYSCTL_FILE="$(env_get SYSCTL_FILE "$TARGET_DIR/.env")"
  NET_SCRIPT="$(env_get NET_SCRIPT "$TARGET_DIR/.env")"
  NET_UNIT="$(env_get NET_UNIT "$TARGET_DIR/.env")"
  NETWORK_NAME="$(env_get NETWORK_NAME "$TARGET_DIR/.env")"
  NETWORK_SUBNET="$(env_get NETWORK_SUBNET "$TARGET_DIR/.env")"
  ROUTING_TABLE_ID="$(env_get ROUTING_TABLE_ID "$TARGET_DIR/.env")"
  ROUTING_RULE_PRIORITY="$(env_get ROUTING_RULE_PRIORITY "$TARGET_DIR/.env")"
  ROUTING_TABLE_NAME="$(env_get ROUTING_TABLE_NAME "$TARGET_DIR/.env")"
fi

remove_ufw_rules_for_node() {
  local node="$1"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status | grep -q "Status: active" || return 0
  mapfile -t nums < <(
    ufw status numbered 2>/dev/null \
      | grep -E "(pnk-node|RemnaNode) ${node}" \
      | awk -F'[][]' '{print $2}' | tr -d ' ' | grep -E '^[0-9]+$' | sort -nr
  )
  [[ "${#nums[@]}" -eq 0 ]] && return 0
  pnk_info "Удаляю UFW правила..."
  for n in "${nums[@]}"; do
    ufw --force delete "$n" >/dev/null 2>&1 || true
  done
  pnk_ok "UFW очищен"
}

echo
pnk_box_top "REMOVE" 52
pnk_box_line "dir        ${ERR}${TARGET_DIR}${NC}"
pnk_box_line "container  ${ERR}${NODE_NAME}${NC}"
[[ -n "$DOCKER_NET_SUBNET" ]] && pnk_box_line "routing    ${ERR}${DOCKER_NET_SUBNET}${NC}"
[[ -n "$SELECTED_IFACE" ]] && pnk_box_line "iface      ${ERR}${SELECTED_IFACE}${NC}"
pnk_box_bottom 52
echo

if ! pnk_confirm "Подтвердите удаление" "N"; then
  pnk_muted "Отменено"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$NODE_NAME"; then
  pnk_info "Останавливаю контейнер..."
  docker compose -f "$TARGET_DIR/docker-compose.yml" down 2>/dev/null || true
  docker rm -f "$NODE_NAME" 2>/dev/null || true
  pnk_ok "Контейнер удалён"
else
  pnk_muted "Контейнер не найден"
fi

remove_ufw_rules_for_node "$NODE_NAME"

# systemd (pnk + legacy remnanode names)
for unit_path in "${NET_UNIT}" \
  "/etc/systemd/system/pnknode-net-${NODE_NAME}.service" \
  "/etc/systemd/system/remnanode-net-${NODE_NAME}.service"; do
  [[ -z "${unit_path:-}" ]] && continue
  [[ -f "$unit_path" ]] || continue
  systemctl disable --now "$(basename "$unit_path")" >/dev/null 2>&1 || true
  rm -f "$unit_path" 2>/dev/null || true
done
for script_path in "${NET_SCRIPT}" \
  "/usr/local/sbin/pnknode-net-${NODE_NAME}.sh" \
  "/usr/local/sbin/remnanode-net-${NODE_NAME}.sh"; do
  [[ -z "${script_path:-}" ]] && continue
  rm -f "$script_path" 2>/dev/null || true
done
systemctl daemon-reload >/dev/null 2>&1 || true

[[ -n "${HOST_RULE_PRIORITY:-}" ]] && ip rule del priority "${HOST_RULE_PRIORITY}" 2>/dev/null || true
[[ -n "${SUBNET_RULE_PRIORITY:-}" ]] && ip rule del priority "${SUBNET_RULE_PRIORITY}" 2>/dev/null || true

SUBNET_CIDR="${DOCKER_NET_SUBNET:-}"
if [[ -z "${SUBNET_CIDR:-}" && -n "${DOCKER_NET_NAME:-}" ]]; then
  SUBNET_CIDR="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
fi
if [[ -n "${SUBNET_CIDR:-}" && -n "${SELECTED_IFACE:-}" ]]; then
  while iptables -t nat -C POSTROUTING -s "${SUBNET_CIDR}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s "${SUBNET_CIDR}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null || break
  done
  while iptables -C FORWARD -s "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -s "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null || break
  done
  while iptables -C FORWARD -d "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -d "${SUBNET_CIDR}" -j ACCEPT 2>/dev/null || break
  done
  pnk_ok "iptables NAT/FORWARD очищены"
fi

for sf in "${SYSCTL_FILE}" "/etc/sysctl.d/99-pnknode-${NODE_NAME}.conf" "/etc/sysctl.d/99-remnanode-${NODE_NAME}.conf"; do
  [[ -n "$sf" && -f "$sf" ]] && rm -f "$sf" 2>/dev/null || true
done
sysctl --system >/dev/null 2>&1 || true

if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save 2>/dev/null || true
elif command -v iptables-save &>/dev/null; then
  mkdir -p /etc/iptables 2>/dev/null || true
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# legacy custom-network cleanup (safe subset)
if [[ "$USE_CUSTOM_NETWORK" == "true" && -n "$NETWORK_SUBNET" ]]; then
  ROUTING_TABLE_ID="${ROUTING_TABLE_ID:-101}"
  ROUTING_RULE_PRIORITY="${ROUTING_RULE_PRIORITY:-1002}"
  ip rule del from "${NETWORK_SUBNET}" lookup "${ROUTING_TABLE_ID}" priority "${ROUTING_RULE_PRIORITY}" 2>/dev/null || true
  if [[ -n "$SELECTED_IFACE" && -n "$BIND_IP" ]]; then
    iptables -t nat -D POSTROUTING -s "${NETWORK_SUBNET}" -o "${SELECTED_IFACE}" -j SNAT --to-source "${BIND_IP}" 2>/dev/null || true
  fi
fi

if [[ -n "${ROUTING_TABLE_ID:-}" && -n "${ROUTING_TABLE_NAME:-}" && -f /etc/iproute2/rt_tables ]]; then
  if [[ "$ROUTING_TABLE_NAME" == "pnknode_${NODE_NAME}" || "$ROUTING_TABLE_NAME" == "remnanode_${NODE_NAME}" ]]; then
    sed -i -E "/^${ROUTING_TABLE_ID}[[:space:]]+${ROUTING_TABLE_NAME}$/d" /etc/iproute2/rt_tables 2>/dev/null || true
  fi
fi

if [[ "$USE_CUSTOM_NETWORK" == "true" && -n "$NETWORK_NAME" && "$NETWORK_NAME" =~ ^br- ]]; then
  SYSTEM_NETWORKS=("bridge" "host" "none")
  skip=false
  for sys_net in "${SYSTEM_NETWORKS[@]}"; do
    [[ "$NETWORK_NAME" == "$sys_net" ]] && skip=true
  done
  if [[ "$skip" == false ]] && docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    others=$(docker network inspect "${NETWORK_NAME}" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -v "^$" | grep -v "^${NODE_NAME}$" | wc -l)
    if [[ "$others" -eq 0 ]]; then
      docker network rm "${NETWORK_NAME}" 2>/dev/null && pnk_ok "Сеть ${NETWORK_NAME} удалена" || true
    fi
  fi
fi

pnk_info "Удаляю ${TARGET_DIR}..."
if [[ -d "$TARGET_DIR" ]]; then
  rm -rf "$TARGET_DIR" 2>/dev/null || true
  if [[ -d "$TARGET_DIR" ]]; then
    pnk_err "Не удалось удалить ${TARGET_DIR} — сделайте вручную: rm -rf ${TARGET_DIR}"
  else
    pnk_ok "Директория удалена"
  fi
fi

echo
pnk_ok "Нода ${TEAL}${NODE_NAME}${NC} полностью удалена"
pnk_footer
