#!/usr/bin/env bash
# pnk-node — interactive menu
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

show_nodes_status() {
  local dirs=() d name status running=0 total=0
  mapfile -t dirs < <(pnk_list_nodes)
  total="${#dirs[@]}"
  if [[ "$total" -eq 0 ]]; then
    pnk_muted "Ноды не установлены"
    return
  fi
  for d in "${dirs[@]}"; do
    name="$(basename "$d")"
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      status="${OK}online${NC}"
      running=$((running + 1))
    elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      status="${WARN}stopped${NC}"
    else
      status="${MUTED}no container${NC}"
    fi
    local port bind
    port="$(grep -E '^(APP_PORT|NODE_PORT)=' "$d/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    bind="$(grep -E '^BIND_IP=' "$d/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    printf "  ${TEAL}●${NC}  ${INK}%-14s${NC}  %b" "$name" "$status"
    [[ -n "$bind" || -n "$port" ]] && printf "  ${MUTED}%s%s${NC}" "${bind:-?}" "${port:+:$port}"
    echo
  done
  pnk_muted "${running}/${total} контейнеров запущено"
}

show_menu() {
  pnk_clear
  pnk_banner "Remnawave Node · control panel"
  pnk_box_top "STATUS" 52
  echo
  show_nodes_status
  echo
  pnk_box_bottom 52
  echo
  pnk_section "Действия"
  pnk_menu_item "1" "Установить ноду" "setup + routing + UFW"
  pnk_menu_item "2" "Удалить ноду" "чистая очистка"
  pnk_menu_item "3" "Безопасность" "UFW + anti-ping"
  pnk_menu_item "4" "Логи ноды" "docker compose logs"
  pnk_menu_item "5" "Обновить ноду" "pull + up -d"
  pnk_menu_item "6" "Статус / диагностика" "ports · rules · health"
  echo
  pnk_section "Extras"
  pnk_menu_item "7" "Self-steal" "Caddy / Nginx · Reality dest"
  pnk_menu_item "8" "BBR" "tcp congestion"
  pnk_menu_item "9" "WARP-NATIVE" "WireGuard · wgcf"
  pnk_menu_item "10" "CDN" "nginx LE · /api → :4443"
  pnk_menu_item "11" "eGames node" "host · selfsteal · version"
  echo
  pnk_menu_item "0" "Выход"
  echo
  pnk_hr 52
  printf "  ${MUTED}wiki-style tip:${NC} ${TEAL}VERBOSE=1${NC} ${MUTED}для подробных логов установки${NC}\n"
  echo
}

pick_node_dir() {
  local dirs=() i choice
  mapfile -t dirs < <(pnk_list_nodes)
  if [[ "${#dirs[@]}" -eq 0 ]]; then
    pnk_warn "Ноды не найдены"
    return 1
  fi
  echo
  for i in "${!dirs[@]}"; do
    printf "  ${TEAL}%d)${NC}  %s\n" "$((i + 1))" "$(basename "${dirs[$i]}")"
  done
  echo
  pnk_ask "Выберите ноду [1-${#dirs[@]}]" choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#dirs[@]} )); then
    pnk_err "Неверный выбор"
    return 1
  fi
  REPLY_NODE_DIR="${dirs[$((choice - 1))]}"
}

action_logs() {
  local dir
  pick_node_dir || return 0
  dir="$REPLY_NODE_DIR"
  pnk_info "Логи ${TEAL}$(basename "$dir")${NC} — Ctrl+C для выхода"
  (cd "$dir" && docker compose logs -f -t) || true
}

action_update() {
  local dir
  pick_node_dir || return 0
  dir="$REPLY_NODE_DIR"
  pnk_section "Обновление $(basename "$dir")"
  (cd "$dir" && docker compose pull && docker compose up -d)
  pnk_ok "Готово"
}

action_diag() {
  local dir name
  pick_node_dir || return 0
  dir="$REPLY_NODE_DIR"
  name="$(basename "$dir")"
  pnk_clear
  pnk_banner "diagnostics"
  pnk_section "$name"
  if [[ -f "$dir/.env" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^(SECRET_KEY|SSL_CERT)= ]] && continue
      pnk_kv "${line%%=*}" "${line#*=}"
    done < <(grep -E '^(NODE_NAME|APP_PORT|NODE_PORT|BIND_IP|SELECTED_IFACE|DOCKER_NET_NAME|ROUTING_TABLE_ID)=' "$dir/.env" 2>/dev/null || true)
  fi
  echo
  if docker ps --format '{{.Names}}' | grep -qx "$name"; then
    pnk_ok "Контейнер запущен"
    docker ps --filter "name=^${name}$" --format 'table {{.Status}}\t{{.Ports}}'
  else
    pnk_warn "Контейнер не запущен"
  fi
  echo
  pnk_section "ip rule (фрагмент)"
  ip rule show 2>/dev/null | head -20 || true
  echo
  if [[ -f "/etc/systemd/system/pnknode-net-${name}.service" ]] || [[ -f "/etc/systemd/system/remnanode-net-${name}.service" ]]; then
    pnk_ok "systemd network unit найден"
  else
    pnk_muted "systemd network unit не найден"
  fi
}

while true; do
  show_menu
  pnk_ask "Ваш выбор" CHOICE
  case "$CHOICE" in
    1)
      pnk_run_peer "$SCRIPT_DIR" "setup-pnknode.sh" || true
      pnk_press_enter
      ;;
    2)
      pnk_run_peer "$SCRIPT_DIR" "remove-pnknode.sh" || true
      pnk_press_enter
      ;;
    3)
      pnk_run_peer "$SCRIPT_DIR" "security-setup.sh" || true
      pnk_press_enter
      ;;
    4)
      action_logs
      pnk_press_enter
      ;;
    5)
      action_update
      pnk_press_enter
      ;;
    6)
      action_diag
      pnk_press_enter
      ;;
    7)
      pnk_run_peer "$SCRIPT_DIR" "setup-selfsteal.sh" || true
      pnk_press_enter
      ;;
    8)
      pnk_run_peer "$SCRIPT_DIR" "setup-bbr.sh" || true
      pnk_press_enter
      ;;
    9)
      pnk_run_peer "$SCRIPT_DIR" "setup-warp.sh" || true
      pnk_press_enter
      ;;
    10)
      pnk_run_peer "$SCRIPT_DIR" "setup-cdn.sh" || true
      pnk_press_enter
      ;;
    11)
      pnk_run_peer "$SCRIPT_DIR" "setup-egames-node.sh" || true
      pnk_press_enter
      ;;
    0|q|Q)
      pnk_clear
      pnk_footer
      exit 0
      ;;
    *)
      pnk_warn "Неверный выбор"
      sleep 1
      ;;
  esac
done
