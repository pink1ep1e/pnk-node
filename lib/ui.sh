#!/usr/bin/env bash
# pnk-node UI kit — turquoise terminal design
# shellcheck disable=SC2034

PNK_NODE_VERSION="${PNK_NODE_VERSION:-1.0.0}"

# ── Palette (truecolor + fallbacks) ──────────────────────────────
if [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]] && [[ -t 1 || -n "${FORCE_COLOR:-}" ]]; then
  TEAL=$'\033[38;2;45;212;191m'
  TEAL_B=$'\033[38;2;94;234;212m'
  TEAL_D=$'\033[38;2;15;118;110m'
  INK=$'\033[38;2;241;245;249m'
  MUTED=$'\033[38;2;100;116;139m'
  OK=$'\033[38;2;52;211;153m'
  WARN=$'\033[38;2;251;191;36m'
  ERR=$'\033[38;2;248;113;113m'
  ACCENT=$'\033[38;2;34;211;238m'
  BG_SOFT=$'\033[48;2;15;23;42m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  TEAL=$'\033[36m'; TEAL_B=$'\033[96m'; TEAL_D=$'\033[36m'
  INK=$'\033[97m'; MUTED=$'\033[90m'
  OK=$'\033[32m'; WARN=$'\033[33m'; ERR=$'\033[31m'
  ACCENT=$'\033[36m'; BG_SOFT=''; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
fi

# ── Glyphs ───────────────────────────────────────────────────────
G_OK="✔"
G_ERR="✖"
G_WARN="!"
G_ARROW="›"
G_DOT="·"
G_STEP="▸"

pnk_clear() { clear 2>/dev/null || printf '\033c'; }

pnk_hr() {
  local w="${1:-52}"
  printf "${TEAL_D}%s${NC}\n" "$(printf '─%.0s' $(seq 1 "$w"))"
}

pnk_banner() {
  local subtitle="${1:-Remnawave Node · installer}"
  printf '%b\n' "${TEAL}"
  printf '%b\n' "  ╭────────────────────────────────────────────────────╮"
  printf '%b\n' "  │                                                    │"
  printf '%b\n' "  │${INK}${BOLD}     ██████╗ ███╗   ██╗██╗  ██╗                    ${NC}${TEAL}│"
  printf '%b\n' "  │${INK}${BOLD}     ██╔══██╗████╗  ██║██║ ██╔╝                    ${NC}${TEAL}│"
  printf '%b\n' "  │${TEAL_B}${BOLD}     ██████╔╝██╔██╗ ██║█████╔╝                     ${NC}${TEAL}│"
  printf '%b\n' "  │${TEAL_B}${BOLD}     ██╔═══╝ ██║╚██╗██║██╔═██╗                     ${NC}${TEAL}│"
  printf '%b\n' "  │${TEAL}${BOLD}     ██║     ██║ ╚████║██║  ██╗                    ${NC}${TEAL}│"
  printf '%b\n' "  │${TEAL_D}${BOLD}     ╚═╝     ╚═╝  ╚═══╝╚═╝  ╚═╝                    ${NC}${TEAL}│"
  printf '%b\n' "  │${MUTED}              n o d e   ·   v${PNK_NODE_VERSION}                 ${TEAL}│"
  printf '%b\n' "  │${MUTED}  ${subtitle}${TEAL}"
  printf '%b\n' "  ╰────────────────────────────────────────────────────╯"
  printf '%b\n' "${NC}"
}

pnk_box_top() {
  local title="$1" w="${2:-52}"
  local inner=$((w - 2))
  local pad=$((inner - ${#title} - 2))
  (( pad < 0 )) && pad=0
  printf "${TEAL}╭─ ${TEAL_B}${BOLD}%s${NC}${TEAL} %s╮${NC}\n" "$title" "$(printf '─%.0s' $(seq 1 "$pad"))"
}

pnk_box_line() {
  local text="$1" w="${2:-52}"
  # strip length estimate without ansi is hard; keep simple padding
  printf "${TEAL}│${NC} %b${NC}\n" "$text"
}

pnk_box_bottom() {
  local w="${2:-52}"
  printf "${TEAL}╰%s╯${NC}\n" "$(printf '─%.0s' $(seq 1 $((w - 2))))"
}

pnk_section() {
  local title="$1"
  echo
  printf "  ${TEAL}${BOLD}%s${NC}  ${MUTED}%s${NC}\n" "$G_STEP" "$title"
  printf "  ${TEAL_D}%s${NC}\n" "$(printf '·%.0s' $(seq 1 44))"
}

pnk_info()  { printf "  ${ACCENT}${G_DOT}${NC}  %b${NC}\n" "$*"; }
pnk_ok()    { printf "  ${OK}${G_OK}${NC}  %b${NC}\n" "$*"; }
pnk_warn()  { printf "  ${WARN}${G_WARN}${NC}  %b${NC}\n" "$*"; }
pnk_err()   { printf "  ${ERR}${G_ERR}${NC}  %b${NC}\n" "$*"; }
pnk_muted() { printf "  ${MUTED}%b${NC}\n" "$*"; }
pnk_kv()    { printf "  ${MUTED}%-14s${NC} ${INK}%b${NC}\n" "$1" "$2"; }

pnk_menu_item() {
  local num="$1" label="$2" hint="${3:-}"
  if [[ -n "$hint" ]]; then
    printf "  ${TEAL}${BOLD}%2s)${NC}  ${INK}%s${NC}  ${MUTED}%s${NC}\n" "$num" "$label" "$hint"
  else
    printf "  ${TEAL}${BOLD}%2s)${NC}  ${INK}%s${NC}\n" "$num" "$label"
  fi
}

pnk_prompt() {
  local msg="$1"
  printf "  ${TEAL}${G_ARROW}${NC}  ${INK}%s${NC} " "$msg"
}

pnk_ask() {
  # usage: pnk_ask "question" VAR [default]
  local q="$1" __var="$2" def="${3:-}"
  local ans
  if [[ -n "$def" ]]; then
    pnk_prompt "${q} ${MUTED}[${def}]${NC}"
  else
    pnk_prompt "$q"
  fi
  read -r ans </dev/tty || true
  [[ -z "$ans" && -n "$def" ]] && ans="$def"
  printf -v "$__var" '%s' "$ans"
}

pnk_confirm() {
  # returns 0 if yes
  local q="$1" def="${2:-N}" ans hint="(y/N)"
  [[ "$def" =~ ^[Yy]$ ]] && hint="(Y/n)"
  pnk_prompt "${q} ${MUTED}${hint}${NC}"
  read -r ans </dev/tty || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

pnk_press_enter() {
  local msg="${1:-Нажмите Enter, чтобы продолжить...}"
  echo
  pnk_muted "$msg"
  read -r </dev/tty || true
}

pnk_step() {
  local n="$1" total="$2" label="$3"
  printf "\n  ${TEAL_D}[%s/%s]${NC} ${TEAL_B}%s${NC}\n" "$n" "$total" "$label"
}

pnk_footer() {
  echo
  pnk_hr 52
  printf "  ${MUTED}pnk-node${NC} ${TEAL_D}·${NC} ${MUTED}turquoise stack for Remnawave Node${NC}\n"
  echo
}
