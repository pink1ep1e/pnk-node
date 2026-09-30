#!/usr/bin/env bash
# pnk-node common helpers
# shellcheck disable=SC2034

PNK_NODE_VERSION="${PNK_NODE_VERSION:-1.0.0}"
PNK_NODE_RAW="${PNK_NODE_RAW:-https://raw.githubusercontent.com/pink1ep1e/pnk-node/refs/heads/main}"

pnk_resolve_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  if [[ -n "$src" && -f "$src" ]]; then
    cd "$(dirname "$src")" && pwd
  else
    echo ""
  fi
}

pnk_load_ui() {
  local here="$1"
  if [[ -n "$here" && -f "$here/lib/ui.sh" ]]; then
    # shellcheck source=/dev/null
    source "$here/lib/ui.sh"
    return 0
  fi
  if [[ -n "${PNK_NODE_RAW:-}" ]]; then
    # shellcheck source=/dev/null
    source <(curl -fsSL "${PNK_NODE_RAW%/}/lib/ui.sh") && return 0
  fi
  # minimal fallback
  TEAL=$'\033[36m'; TEAL_B=$'\033[96m'; TEAL_D=$'\033[36m'
  INK=$'\033[97m'; MUTED=$'\033[90m'
  OK=$'\033[32m'; WARN=$'\033[33m'; ERR=$'\033[31m'
  ACCENT=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
  G_OK="✔"; G_ERR="✖"; G_WARN="!"; G_ARROW="›"; G_DOT="·"; G_STEP="▸"
  pnk_clear() { clear 2>/dev/null || true; }
  pnk_banner() { echo "pnk-node"; }
  pnk_hr() { echo "----"; }
  pnk_section() { echo; echo ">> $1"; }
  pnk_info() { echo " · $*"; }
  pnk_ok() { echo " ✔ $*"; }
  pnk_warn() { echo " ! $*"; }
  pnk_err() { echo " ✖ $*"; }
  pnk_muted() { echo " $*"; }
  pnk_kv() { echo " $1 $2"; }
  pnk_menu_item() { echo " $1) $2"; }
  pnk_prompt() { printf " › %s " "$1"; }
  pnk_ask() { local q="$1" v="$2" d="${3:-}" a; printf " › %s " "$q"; read -r a </dev/tty; [[ -z "$a" && -n "$d" ]] && a="$d"; printf -v "$v" '%s' "$a"; }
  pnk_confirm() { local a; printf " › %s (y/N) " "$1"; read -r a </dev/tty; [[ "${a:-N}" =~ ^[Yy]$ ]]; }
  pnk_press_enter() { read -r </dev/tty || true; }
  pnk_step() { echo "[$1/$2] $3"; }
  pnk_footer() { echo; }
  pnk_box_top() { echo "== $1 =="; }
  pnk_box_line() { echo " $1"; }
  pnk_box_bottom() { echo "========"; }
}

pnk_require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    pnk_err "Запусти от root: ${MUTED}sudo bash $0${NC}"
    exit 1
  fi
}

pnk_run_peer() {
  # Run sibling script locally or via PNK_NODE_RAW
  local here="$1" name="$2"
  shift 2
  if [[ -n "$here" && -f "$here/$name" ]]; then
    bash "$here/$name" "$@"
    return $?
  fi
  if [[ -n "${PNK_NODE_RAW:-}" ]]; then
    bash <(curl -fsSL "${PNK_NODE_RAW%/}/$name") "$@"
    return $?
  fi
  pnk_err "Не найден $name. Запускай из клона репозитория или задай PNK_NODE_RAW."
  return 1
}

pnk_list_nodes() {
  find /opt -maxdepth 1 -type d \( -name 'pnknode*' -o -name 'remnanode*' \) 2>/dev/null | sort
}
