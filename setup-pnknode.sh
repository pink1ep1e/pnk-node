#!/usr/bin/env bash
# pnk-node — install Remnawave Node (multi-IP aware)
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
if [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/common.sh"
else
  echo "Запускай из клона репозитория или через install.sh + PNK_NODE_RAW"; exit 1
fi
pnk_load_ui "${SCRIPT_DIR}"

VERBOSE="${VERBOSE:-0}"
XRAY_PORT_HTTPS="8443"
XRAY_PORT_ALT="4443"
PUBLISH_XRAY_PORTS_DEFAULT="true"

STAGE_DIR=""
TARGET_DIR=""
CREATED_NETWORK_BY_SCRIPT="false"
NETWORK_NAME=""
INSTALL_SUCCESS="false"
CONTAINER_STARTED="false"
NODE_NAME=""

cleanup() {
  if [[ -n "${STAGE_DIR:-}" && -d "${STAGE_DIR:-}" ]]; then
    rm -rf "${STAGE_DIR}" 2>/dev/null || true
  fi
  if [[ "${INSTALL_SUCCESS:-false}" != "true" && "${CONTAINER_STARTED:-false}" == "true" && -n "${NODE_NAME:-}" ]]; then
    docker rm -f "${NODE_NAME}" >/dev/null 2>&1 || true
  fi
  if [[ "${INSTALL_SUCCESS:-false}" != "true" && "${CREATED_NETWORK_BY_SCRIPT:-false}" == "true" && -n "${NETWORK_NAME:-}" ]]; then
    docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
  fi
}

on_err() {
  local exit_code=$?
  echo
  pnk_err "Ошибка установки (код ${exit_code})"
  cleanup
  exit "${exit_code}"
}

trap on_err ERR
trap cleanup EXIT

pnk_clear
pnk_banner "install wizard"
pnk_require_root

# ── packages ─────────────────────────────────────────────────────
ensure_packages() {
  local missing=()
  for cmd in ip awk sed grep cut tr; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  if [[ "${#missing[@]}" -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      pnk_info "Устанавливаю зависимости: curl, iproute2 ..."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y curl ca-certificates iproute2 >/dev/null
    else
      pnk_warn "Нет apt-get. Нужны: curl, iproute2"
    fi
  fi
}

get_default_gw_for_iface() {
  local iface="$1"
  ip route show default dev "${iface}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true
}

get_default_gw_for_src() {
  local src_ip="$1"
  ip route show default 2>/dev/null | grep -m1 "src ${src_ip}" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true
}

ensure_rt_table_id() {
  local table_name="$1" id=""
  if [[ -f /etc/iproute2/rt_tables ]]; then
    id="$(awk -v n="$table_name" '$2==n {print $1; exit}' /etc/iproute2/rt_tables 2>/dev/null || true)"
  fi
  if [[ -n "$id" ]]; then echo "$id"; return 0; fi
  for candidate in $(seq 201 250); do
    if ! awk -v c="$candidate" '$1==c {found=1} END{exit found?0:1}' /etc/iproute2/rt_tables 2>/dev/null; then
      echo "$candidate"; return 0
    fi
  done
  echo "250"
}

ensure_ip_rule_prio_from_lookup() {
  local prio="$1" from="$2" lookup="$3"
  if ip rule show 2>/dev/null | grep -qE "^${prio}:.*from ${from}.*lookup ${lookup}"; then return 0; fi
  if ip rule show 2>/dev/null | grep -qE "^${prio}:.*from ${from} "; then
    ip rule del priority "${prio}" 2>/dev/null || true
  fi
  ip rule add priority "${prio}" from "${from}" lookup "${lookup}" 2>/dev/null || true
}

ensure_iptables_rule() {
  local table="$1"; shift
  local chain="$1"; shift
  if iptables -t "${table}" -C "${chain}" "$@" 2>/dev/null; then return 0; fi
  iptables -t "${table}" -A "${chain}" "$@" 2>/dev/null || true
}

persist_iptables_if_possible() {
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>/dev/null || true
  elif command -v iptables-save &>/dev/null; then
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

ensure_iptables_persistence() {
  if command -v netfilter-persistent &>/dev/null; then
    systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if command -v debconf-set-selections >/dev/null 2>&1; then
      echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections || true
      echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections || true
    fi
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
    systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
  fi
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.1[6-9]\. ]] && return 0
  [[ "$ip" =~ ^172\.2[0-9]\. ]] && return 0
  [[ "$ip" =~ ^172\.3[0-1]\. ]] && return 0
  [[ "$ip" =~ ^100\.6[4-9]\. ]] && return 0
  [[ "$ip" =~ ^100\.(7[0-9]|[8-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  return 1
}

is_port_in_use() {
  local ip="$1" port="$2" proto="$3"
  if [[ "$proto" == "tcp" ]]; then
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^${ip}:${port}$|^0\\.0\\.0\\.0:${port}$|^\\[::\\]:${port}$)" && return 0
  elif [[ "$proto" == "udp" ]]; then
    ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^${ip}:${port}$|^0\\.0\\.0\\.0:${port}$|^\\[::\\]:${port}$)" && return 0
  fi
  return 1
}

sanitize_secret_key() {
  local k="$1"
  k="$(echo "$k" | sed -E 's/^[[:space:]]*SSL_CERT[[:space:]]*=[[:space:]]*//')"
  k="$(echo "$k" | sed -E 's/^[[:space:]]*SECRET_KEY[[:space:]]*=[[:space:]]*//')"
  k="$(echo "$k" | sed -E 's/^[[:space:]]*["'\'']?//' | sed -E 's/["'\'']?[[:space:]]*$//')"
  k="$(echo "$k" | sed -E 's/^[[:space:]]+//' | sed -E 's/[[:space:]]+$//')"
  echo "$k"
}

is_secret_key_unique() {
  local candidate="$1" env_file sk node
  while IFS= read -r -d '' env_file; do
    sk="$(grep -E '^SECRET_KEY=' "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2- || true)"
    sk="$(echo "$sk" | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//')"
    if [[ -n "$sk" && "$sk" == "$candidate" ]]; then
      node="$(basename "$(dirname "$env_file")")"
      pnk_err "SECRET_KEY уже у ноды: ${TEAL}${node}${NC}"
      return 1
    fi
  done < <(find /opt -maxdepth 2 -type f -name ".env" \( -path "/opt/pnknode*/.env" -o -path "/opt/remnanode*/.env" \) -print0 2>/dev/null || true)
  return 0
}

ensure_packages
pnk_step 1 7 "Окружение"

if ! command -v docker &>/dev/null; then
  pnk_info "Docker не найден — ставлю get.docker.com"
  curl -fsSL https://get.docker.com | sh
else
  pnk_ok "Docker уже установлен"
  systemctl is-active --quiet docker || systemctl start docker
fi

# ── target dir ───────────────────────────────────────────────────
BASE_DIR="/opt/pnknode"
TARGET_DIR="$BASE_DIR"
IDX=1
while [[ -d "$TARGET_DIR" ]]; do
  IDX=$((IDX + 1))
  TARGET_DIR="${BASE_DIR}${IDX}"
done
NODE_NAME="$(basename "$TARGET_DIR")"

pnk_kv "directory" "$TARGET_DIR"
pnk_kv "container" "$NODE_NAME"

# ── port ─────────────────────────────────────────────────────────
pnk_step 2 7 "Порт API"
pnk_ask "Порт приложения" NODE_PORT "2222"
NODE_PORT="${NODE_PORT:-2222}"

# ── interfaces ───────────────────────────────────────────────────
pnk_step 3 7 "Сетевой интерфейс"
pnk_section "IPv4 · iface → local → public"

declare -a IF_NAMES IF_IPS IF_EXTERNALS
mapfile -t ADDR_LINES < <(ip -o -4 addr show scope global | awk '{print $2, $4}' | sed 's#/.*##')

for line in "${ADDR_LINES[@]}"; do
  IF_NAME="$(awk '{print $1}' <<<"$line")"
  IF_IP="$(awk '{print $2}' <<<"$line")"
  [[ "$IF_NAME" == "lo" ]] && continue
  [[ "$IF_NAME" =~ ^(docker|br-|veth|virbr|lxcbr) ]] && continue
  IF_NAMES+=("$IF_NAME")
  IF_IPS+=("$IF_IP")
done

if [[ "${#IF_NAMES[@]}" -eq 0 ]]; then
  for line in "${ADDR_LINES[@]}"; do
    IF_NAME="$(awk '{print $1}' <<<"$line")"
    IF_IP="$(awk '{print $2}' <<<"$line")"
    [[ "$IF_NAME" == "lo" ]] && continue
    IF_NAMES+=("$IF_NAME")
    IF_IPS+=("$IF_IP")
  done
fi

if [[ "${#IF_NAMES[@]}" -eq 0 ]]; then
  pnk_err "Не найдено IPv4 адресов (scope global)"
  exit 1
fi

pnk_muted "Определяю внешний IP для NAT-адресов..."
for i in "${!IF_NAMES[@]}"; do
  IF_NAME="${IF_NAMES[$i]}"
  IF_IP="${IF_IPS[$i]}"
  if is_private_ipv4 "$IF_IP"; then
    EXTERNAL_IP="$(curl -4 -s --interface "${IF_NAME}" --max-time 2 ifconfig.me 2>/dev/null || true)"
    IF_EXTERNALS[$i]="${EXTERNAL_IP:-}"
  else
    IF_EXTERNALS[$i]="$IF_IP"
  fi
done

echo
for i in "${!IF_NAMES[@]}"; do
  IF_NAME="${IF_NAMES[$i]}"
  IF_IP="${IF_IPS[$i]}"
  EXTERNAL_IP="${IF_EXTERNALS[$i]:-}"
  if [[ -n "$EXTERNAL_IP" ]]; then
    printf "  ${TEAL}${BOLD}[%d]${NC}  %-12s ${MUTED}→${NC} ${INK}%s${NC}  ${MUTED}→ public${NC} ${TEAL_B}%s${NC}\n" \
      "$((i + 1))" "$IF_NAME" "$IF_IP" "$EXTERNAL_IP"
  else
    printf "  ${TEAL}${BOLD}[%d]${NC}  %-12s ${MUTED}→${NC} ${INK}%s${NC}  ${MUTED}→ public (n/a)${NC}\n" \
      "$((i + 1))" "$IF_NAME" "$IF_IP"
  fi
done
echo

pnk_ask "Выберите IP/интерфейс [1-${#IF_NAMES[@]}]" IF_CHOICE
if ! [[ "$IF_CHOICE" =~ ^[0-9]+$ ]] || (( IF_CHOICE < 1 || IF_CHOICE > ${#IF_NAMES[@]} )); then
  pnk_err "Неверный выбор интерфейса"
  exit 1
fi

SELECTED_IFACE="${IF_NAMES[$((IF_CHOICE - 1))]}"
BIND_IP="${IF_IPS[$((IF_CHOICE - 1))]}"
EXTERNAL_IP_DETECTED="${IF_EXTERNALS[$((IF_CHOICE - 1))]:-}"

pnk_ok "iface ${TEAL}${SELECTED_IFACE}${NC} · bind ${TEAL_B}${BIND_IP}${NC}${EXTERNAL_IP_DETECTED:+ · public ${TEAL_B}${EXTERNAL_IP_DETECTED}${NC}}"

USE_CUSTOM_NETWORK="false"
NETWORK_NAME=""
PUBLISH_XRAY_PORTS="${PUBLISH_XRAY_PORTS_DEFAULT}"
ROUTING_TABLE_ID="" ROUTING_TABLE_NAME=""
HOST_RULE_PRIORITY="" SUBNET_RULE_PRIORITY=""
DOCKER_NET_NAME="" DOCKER_NET_SUBNET="" DOCKER_BRIDGE_IFACE=""

# ── secret ───────────────────────────────────────────────────────
pnk_step 4 7 "SECRET_KEY"
pnk_ask "Вставьте SECRET_KEY из панели" SECRET_KEY
SECRET_KEY="$(sanitize_secret_key "$SECRET_KEY")"
if [[ -z "$SECRET_KEY" ]]; then
  pnk_err "SECRET_KEY не может быть пустым"
  exit 1
fi

while ! is_secret_key_unique "$SECRET_KEY"; do
  pnk_warn "Нужен другой уникальный ключ"
  pnk_ask "SECRET_KEY" SECRET_KEY
  SECRET_KEY="$(sanitize_secret_key "$SECRET_KEY")"
  [[ -n "$SECRET_KEY" ]] || pnk_err "SECRET_KEY пустой"
done
pnk_ok "SECRET_KEY принят"

# ── version ──────────────────────────────────────────────────────
pnk_step 5 7 "Версия образа"
echo
pnk_menu_item "1" "latest" "рекомендуется"
pnk_menu_item "2" "2.8.0" "legacy"
pnk_menu_item "3" "Вручную" "tag / semver"
echo
pnk_ask "Выбор [1-3]" VERSION_CHOICE "1"
case "$VERSION_CHOICE" in
  2) NODE_VERSION="2.8.0" ;;
  3)
    pnk_ask "Версия (например 2.8.0)" NODE_VERSION
    [[ -n "$NODE_VERSION" ]] || { pnk_err "Версия пустая"; exit 1; }
    ;;
  *) NODE_VERSION="latest" ;;
esac
pnk_ok "image remnawave/node:${TEAL}${NODE_VERSION}${NC}"

# ── port checks ──────────────────────────────────────────────────
pnk_step 6 7 "Проверка портов"
check_xray_ports_or_exit() {
  local ip="$1"
  [[ "${PUBLISH_XRAY_PORTS:-true}" == "true" ]] || return 0
  for p in "${XRAY_PORT_HTTPS}" "${XRAY_PORT_ALT}"; do
    local conflict="false"
    is_port_in_use "$ip" "$p" "tcp" && conflict="true"
    is_port_in_use "$ip" "$p" "udp" && conflict="true"
    if docker ps --format '{{.Ports}}' | grep -qE "${ip}:${p}"; then conflict="true"; fi
    if [[ "$conflict" == "true" ]]; then
      pnk_err "Порт ${p} на ${ip} занят"
      pnk_muted "Освободите порт, смените IP, или PUBLISH_XRAY_PORTS_DEFAULT=false"
      exit 1
    fi
  done
}
check_xray_ports_or_exit "${BIND_IP}"

if docker ps --format '{{.Ports}}' | grep -q "${BIND_IP}:${NODE_PORT}"; then
  OCCUPIED_CONTAINER=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep "${BIND_IP}:${NODE_PORT}" | awk '{print $1}' | head -1)
  pnk_err "Порт ${NODE_PORT} занят контейнером ${OCCUPIED_CONTAINER}"
  pnk_ask "Другой порт (Enter = отмена)" NEW_PORT
  [[ -n "$NEW_PORT" ]] || { pnk_err "Отменено"; exit 1; }
  NODE_PORT="$NEW_PORT"
fi

if ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^${BIND_IP}:${NODE_PORT}$|^0\.0\.0\.0:${NODE_PORT}$|^\[::\]:${NODE_PORT}$)"; then
  pnk_warn "Порт ${NODE_PORT} уже LISTEN на хосте"
  pnk_ask "Другой порт (Enter = отмена)" NEW_PORT
  [[ -n "$NEW_PORT" ]] || { pnk_err "Отменено"; exit 1; }
  NODE_PORT="$NEW_PORT"
fi
pnk_ok "Порты свободны"

# ── staging ──────────────────────────────────────────────────────
pnk_step 7 7 "Деплой"
mkdir -p /opt
STAGE_DIR="$(mktemp -d /opt/.pnknode-setup.XXXXXX)"
cd "$STAGE_DIR"

pnk_info "Пишу .env + docker-compose.yml"
cat > .env <<EOF
COMPOSE_PROJECT_NAME=$NODE_NAME
NODE_NAME=$NODE_NAME
APP_PORT=$NODE_PORT
NODE_PORT=$NODE_PORT
BIND_IP=$BIND_IP
SELECTED_IFACE=$SELECTED_IFACE
SECRET_KEY="$SECRET_KEY"
USE_CUSTOM_NETWORK=$USE_CUSTOM_NETWORK
PUBLISH_XRAY_PORTS=$PUBLISH_XRAY_PORTS
XRAY_PORT_HTTPS=$XRAY_PORT_HTTPS
XRAY_PORT_ALT=$XRAY_PORT_ALT
NODE_VERSION=$NODE_VERSION
MANAGED_BY=pnk-node
EOF

XRAY_PORTS_BLOCK=""
if [[ "${PUBLISH_XRAY_PORTS:-true}" == "true" ]]; then
  XRAY_PORTS_BLOCK=$(cat <<'EOF'
      - "${BIND_IP}:${XRAY_PORT_HTTPS}:${XRAY_PORT_HTTPS}/tcp"
      - "${BIND_IP}:${XRAY_PORT_HTTPS}:${XRAY_PORT_HTTPS}/udp"
      - "${BIND_IP}:${XRAY_PORT_ALT}:${XRAY_PORT_ALT}/tcp"
      - "${BIND_IP}:${XRAY_PORT_ALT}:${XRAY_PORT_ALT}/udp"
EOF
)
fi

cat > docker-compose.yml <<EOF
name: $NODE_NAME
services:
  $NODE_NAME:
    container_name: $NODE_NAME
    volumes:
     - '/var/log/remnanode:/var/log/remnanode'
    hostname: $NODE_NAME
    image: remnawave/node:$NODE_VERSION
    restart: always
    env_file:
      - .env
    ports:
      - "\${BIND_IP}:\${NODE_PORT}:\${APP_PORT}"
${XRAY_PORTS_BLOCK}
EOF

pnk_info "Запускаю контейнер ${TEAL}${NODE_NAME}${NC}..."
docker compose up -d

if docker ps | grep -q "$NODE_NAME"; then
  pnk_ok "Контейнер запущен"
  CONTAINER_STARTED="true"
  if [[ -n "${EXTERNAL_IP_DETECTED:-}" ]]; then
    pnk_kv "access" "${EXTERNAL_IP_DETECTED}:${NODE_PORT}"
  else
    pnk_kv "access" "${BIND_IP}:${NODE_PORT}"
  fi
else
  pnk_err "Контейнер не стартовал"
  docker compose logs
  exit 1
fi

# ── policy routing ───────────────────────────────────────────────
pnk_section "Policy routing / NAT → ${SELECTED_IFACE}"
ROUTING_TABLE_NAME="pnknode_${NODE_NAME}"
ROUTING_TABLE_ID="$(ensure_rt_table_id "${ROUTING_TABLE_NAME}")"
HOST_RULE_PRIORITY="$((11000 + ROUTING_TABLE_ID))"
SUBNET_RULE_PRIORITY="$((12000 + ROUTING_TABLE_ID))"

if ! grep -q -E "^${ROUTING_TABLE_ID}[[:space:]]+${ROUTING_TABLE_NAME}$" /etc/iproute2/rt_tables 2>/dev/null; then
  echo "${ROUTING_TABLE_ID} ${ROUTING_TABLE_NAME}" >> /etc/iproute2/rt_tables 2>/dev/null || true
fi

GW="$(get_default_gw_for_iface "${SELECTED_IFACE}")"
GW="${GW:-$(get_default_gw_for_src "${BIND_IP}")}"

if [[ -z "${GW:-}" ]]; then
  pnk_warn "Gateway для ${SELECTED_IFACE} не найден — policy routing пропущен"
else
  ip route replace default via "${GW}" dev "${SELECTED_IFACE}" table "${ROUTING_TABLE_ID}" 2>/dev/null || true
  ensure_ip_rule_prio_from_lookup "${HOST_RULE_PRIORITY}" "${BIND_IP}/32" "${ROUTING_TABLE_ID}"
  pnk_ok "table ${ROUTING_TABLE_ID} via ${GW}"
fi

DOCKER_NET_NAME="$(docker inspect "${NODE_NAME}" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null | awk '{print $1}' || true)"
if [[ -n "${DOCKER_NET_NAME:-}" ]]; then
  DOCKER_NET_SUBNET="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  DOCKER_NET_ID="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{.Id}}' 2>/dev/null | cut -c1-12 || true)"
  [[ -n "${DOCKER_NET_ID:-}" ]] && DOCKER_BRIDGE_IFACE="br-${DOCKER_NET_ID}" || DOCKER_BRIDGE_IFACE=""
fi

if [[ -n "${DOCKER_NET_SUBNET:-}" && -n "${GW:-}" ]]; then
  [[ -n "${DOCKER_BRIDGE_IFACE:-}" ]] && ip route replace "${DOCKER_NET_SUBNET}" dev "${DOCKER_BRIDGE_IFACE}" scope link table "${ROUTING_TABLE_ID}" 2>/dev/null || true
  ensure_ip_rule_prio_from_lookup "${SUBNET_RULE_PRIORITY}" "${DOCKER_NET_SUBNET}" "${ROUTING_TABLE_ID}"
  ensure_iptables_rule nat POSTROUTING -s "${DOCKER_NET_SUBNET}" -o "${SELECTED_IFACE}" -j MASQUERADE
  ensure_iptables_rule filter FORWARD -s "${DOCKER_NET_SUBNET}" -j ACCEPT
  ensure_iptables_rule filter FORWARD -d "${DOCKER_NET_SUBNET}" -j ACCEPT
  ensure_iptables_persistence
  persist_iptables_if_possible
  pnk_ok "NAT/FORWARD для ${DOCKER_NET_SUBNET}"
else
  pnk_warn "Docker subnet/gateway не определены — NAT пропущен"
fi

SYSCTL_FILE="/etc/sysctl.d/99-pnknode-${NODE_NAME}.conf"
cat > "${SYSCTL_FILE}" <<EOF
# Managed by pnk-node (${NODE_NAME})
net.ipv4.conf.${SELECTED_IFACE}.rp_filter=0
EOF
sysctl -p "${SYSCTL_FILE}" >/dev/null 2>&1 || true

NET_SCRIPT="/usr/local/sbin/pnknode-net-${NODE_NAME}.sh"
NET_UNIT="/etc/systemd/system/pnknode-net-${NODE_NAME}.service"

cat > "${NET_SCRIPT}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
NODE_NAME="__NODE_NAME__"
CONF="/opt/__NODE_NAME__/.env"
getv() { grep -E "^$1=" "$CONF" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r' || true; }
BIND_IP="$(getv BIND_IP)"
SELECTED_IFACE="$(getv SELECTED_IFACE)"
ROUTING_TABLE_ID="$(getv ROUTING_TABLE_ID)"
HOST_RULE_PRIORITY="$(getv HOST_RULE_PRIORITY)"
SUBNET_RULE_PRIORITY="$(getv SUBNET_RULE_PRIORITY)"
DOCKER_NET_NAME="$(getv DOCKER_NET_NAME)"
SYSCTL_FILE="$(getv SYSCTL_FILE)"
[[ -n "${BIND_IP:-}" && -n "${SELECTED_IFACE:-}" && -n "${ROUTING_TABLE_ID:-}" ]] || exit 0
GW="$(ip route show default dev "${SELECTED_IFACE}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
if [[ -z "${GW:-}" ]]; then
  GW="$(ip route show default 2>/dev/null | grep -m1 "src ${BIND_IP}" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' || true)"
fi
[[ -n "${GW:-}" ]] || exit 0
ip route replace default via "${GW}" dev "${SELECTED_IFACE}" table "${ROUTING_TABLE_ID}" 2>/dev/null || true
if [[ -n "${HOST_RULE_PRIORITY:-}" ]]; then
  ip rule del priority "${HOST_RULE_PRIORITY}" 2>/dev/null || true
  ip rule add priority "${HOST_RULE_PRIORITY}" from "${BIND_IP}/32" lookup "${ROUTING_TABLE_ID}" 2>/dev/null || true
fi
if [[ -n "${DOCKER_NET_NAME:-}" ]]; then
  SUBNET="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  NETID="$(docker network inspect "${DOCKER_NET_NAME}" --format '{{.Id}}' 2>/dev/null | cut -c1-12 || true)"
  BRIF=""; [[ -n "${NETID:-}" ]] && BRIF="br-${NETID}"
  if [[ -n "${SUBNET:-}" && -n "${SUBNET_RULE_PRIORITY:-}" ]]; then
    ip rule del priority "${SUBNET_RULE_PRIORITY}" 2>/dev/null || true
    ip rule add priority "${SUBNET_RULE_PRIORITY}" from "${SUBNET}" lookup "${ROUTING_TABLE_ID}" 2>/dev/null || true
    [[ -n "${BRIF:-}" ]] && ip route replace "${SUBNET}" dev "${BRIF}" scope link table "${ROUTING_TABLE_ID}" 2>/dev/null || true
    iptables -t nat -C POSTROUTING -s "${SUBNET}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "${SUBNET}" -o "${SELECTED_IFACE}" -j MASQUERADE 2>/dev/null || true
    iptables -C FORWARD -s "${SUBNET}" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s "${SUBNET}" -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -d "${SUBNET}" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d "${SUBNET}" -j ACCEPT 2>/dev/null || true
  fi
fi
if [[ -n "${SYSCTL_FILE:-}" && -f "${SYSCTL_FILE}" ]]; then
  sysctl -p "${SYSCTL_FILE}" >/dev/null 2>&1 || true
fi
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
elif command -v iptables-save >/dev/null 2>&1; then
  mkdir -p /etc/iptables 2>/dev/null || true
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi
EOS

sed -i "s/__NODE_NAME__/${NODE_NAME}/g" "${NET_SCRIPT}" 2>/dev/null || true
chmod 0755 "${NET_SCRIPT}" 2>/dev/null || true

cat > "${NET_UNIT}" <<EOF
[Unit]
Description=pnk-node network rules for ${NODE_NAME}
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${NET_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now "pnknode-net-${NODE_NAME}.service" >/dev/null 2>&1 || true
pnk_ok "systemd unit pnknode-net-${NODE_NAME}"

for kv in \
  "ROUTING_TABLE_ID=${ROUTING_TABLE_ID}" \
  "ROUTING_TABLE_NAME=${ROUTING_TABLE_NAME}" \
  "HOST_RULE_PRIORITY=${HOST_RULE_PRIORITY}" \
  "SUBNET_RULE_PRIORITY=${SUBNET_RULE_PRIORITY}" \
  "DOCKER_NET_NAME=${DOCKER_NET_NAME:-}" \
  "DOCKER_NET_SUBNET=${DOCKER_NET_SUBNET:-}" \
  "DOCKER_BRIDGE_IFACE=${DOCKER_BRIDGE_IFACE:-}" \
  "SYSCTL_FILE=${SYSCTL_FILE}" \
  "NET_SCRIPT=${NET_SCRIPT}" \
  "NET_UNIT=${NET_UNIT}"; do
  k="${kv%%=*}"; v="${kv#*=}"
  if grep -q "^${k}=" .env 2>/dev/null; then
    sed -i "s#^${k}=.*#${k}=${v}#" .env 2>/dev/null || true
  else
    echo "${k}=${v}" >> .env
  fi
done

# ── UFW · panel IP → API port ───────────────────────────────────
echo
pnk_section "UFW · доступ панели к API :${NODE_PORT}"
pnk_muted "Только IP панели сможет стучаться на ${BIND_IP}:${NODE_PORT}/tcp"
PANEL_IP=""
while true; do
  pnk_ask "IP панели Remnawave" PANEL_IP
  if [[ "$PANEL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    break
  fi
  pnk_err "Нужен IPv4, например 203.0.113.10"
done
pnk_ok "Панель ${TEAL}${PANEL_IP}${NC} → :${NODE_PORT}"

if ! command -v ufw &>/dev/null; then
  if command -v apt-get &>/dev/null; then
    pnk_info "Ставлю ufw..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y ufw >/dev/null
  else
    pnk_warn "ufw не найден — правило не добавлено"
  fi
fi

if command -v ufw &>/dev/null; then
  if ! ufw status | grep -q "Status: active"; then
    SSH_PORT="$(ss -tnlp 2>/dev/null | grep -i sshd | awk '{print $4}' | sed 's/.*://g' | sort -u | head -n1 || true)"
    SSH_PORT="${SSH_PORT:-22}"
    ufw allow "${SSH_PORT}/tcp" comment 'SSH Port' >/dev/null 2>&1 || true
    pnk_info "Включаю UFW (SSH :${SSH_PORT} уже разрешён)..."
    ufw --force enable >/dev/null
  fi
  # API только с IP панели
  ufw allow from "${PANEL_IP}" to "${BIND_IP}" port "${NODE_PORT}" proto tcp \
    comment "pnk-node ${NODE_NAME} api from panel ${PANEL_IP}" >/dev/null 2>&1 || true
  # Xray — публично (клиенты)
  ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_HTTPS}" proto tcp \
    comment "pnk-node ${NODE_NAME} xray tcp ${XRAY_PORT_HTTPS}" >/dev/null 2>&1 || true
  ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_HTTPS}" proto udp \
    comment "pnk-node ${NODE_NAME} xray udp ${XRAY_PORT_HTTPS}" >/dev/null 2>&1 || true
  ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_ALT}" proto tcp \
    comment "pnk-node ${NODE_NAME} xray tcp ${XRAY_PORT_ALT}" >/dev/null 2>&1 || true
  ufw allow in on "${SELECTED_IFACE}" to "${BIND_IP}" port "${XRAY_PORT_ALT}" proto udp \
    comment "pnk-node ${NODE_NAME} xray udp ${XRAY_PORT_ALT}" >/dev/null 2>&1 || true
  if [[ -n "${DOCKER_NET_SUBNET:-}" && -n "${DOCKER_BRIDGE_IFACE:-}" ]]; then
    ufw route allow in on "${DOCKER_BRIDGE_IFACE}" out on "${SELECTED_IFACE}" from "${DOCKER_NET_SUBNET}" to any \
      comment "pnk-node ${NODE_NAME} routed egress" >/dev/null 2>&1 || true
  fi
  pnk_ok "UFW: API только с ${PANEL_IP}, Xray открыт"
else
  pnk_warn "UFW недоступен — сохрани IP панели в .env вручную при необходимости"
fi

# persist panel IP
if grep -q '^PANEL_IP=' .env 2>/dev/null; then
  sed -i "s#^PANEL_IP=.*#PANEL_IP=${PANEL_IP}#" .env 2>/dev/null || true
else
  echo "PANEL_IP=${PANEL_IP}" >> .env
fi

# ── finalize ─────────────────────────────────────────────────────
pnk_info "Перенос в ${TEAL}${TARGET_DIR}${NC}"
mv "$STAGE_DIR" "$TARGET_DIR"
STAGE_DIR=""
cd "$TARGET_DIR"
INSTALL_SUCCESS="true"

echo
pnk_box_top "DONE" 52
pnk_box_line "${OK}${G_OK}${NC}  Нода ${TEAL_B}${NODE_NAME}${NC} установлена"
pnk_box_line "    ${MUTED}dir${NC}  ${TARGET_DIR}"
if [[ -n "${EXTERNAL_IP_DETECTED:-}" ]]; then
  pnk_box_line "    ${MUTED}url${NC}  ${TEAL}${EXTERNAL_IP_DETECTED}:${NODE_PORT}${NC}"
else
  pnk_box_line "    ${MUTED}url${NC}  ${TEAL}${BIND_IP}:${NODE_PORT}${NC}"
fi
pnk_box_line "    ${MUTED}ufw${NC}  :${NODE_PORT} ← ${PANEL_IP}"
pnk_box_bottom 52

if pnk_confirm "Показать логи сейчас?" "Y"; then
  pnk_muted "Ctrl+C — выход из логов"
  set +e
  docker compose logs -f -t
  set -e
fi

pnk_footer
