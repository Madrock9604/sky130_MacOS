#!/bin/sh
# SKY130 macOS — Aggressive Uninstaller (POSIX sh)
# Finds and removes SKY130A PDK + Magic (brew/ports/user-built) and config so
# Magic no longer auto-loads sky130A.

set -eu

YES=false
DRY=false

# ---------- args ----------
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '1,200p' "$0"; exit 0 ;;
    *) printf '[!] Unknown arg: %s\n' "$1" ;;
  esac
  shift
done

# ---------- helpers ----------
info() { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$*"; exit 1; }

confirm() {
  prompt="$1"
  if [ "$YES" = true ]; then return 0; fi
  printf '%s [y/N]: ' "$prompt"
  read ans || ans=""
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

run() {
  if [ "$DRY" = true ] ; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    # shellcheck disable=SC2086
    sh -c "$*"
  fi
}

rmrf() {
  tgt="$1"
  if [ ! -e "$tgt" ]; then info "Not found: $tgt"; return 0; fi
  run "rm -rf -- '$tgt'"
  ok "Removed: $tgt"
}

# tty/GUI-aware privilege elevation (for MacPorts)
HAS_TTY=0; [ -t 1 ] && HAS_TTY=1
run_admin() {
  _cmd="$1"
  if [ "$DRY" = true ]; then
    [ "$HAS_TTY" -eq 1 ] && printf 'DRY-RUN sudo %s\n' "$_cmd" || printf 'DRY-RUN (GUI sudo) %s\n' "$_cmd"
    return 0
  fi
  if [ "$HAS_TTY" -eq 1 ]; then
    sudo -n true 2>/dev/null || sudo -v || fail "Admin privileges required"
    sh -c "sudo $_cmd"
  else
    _esc=`printf %s "$_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g'`
    /usr/bin/osascript -e "do shell script \"$_esc\" with administrator privileges"
  fi
}

# in-place delete block [BEGIN..END] without sed -i dependency
delete_block_in_file() {
  # $1=start regex, $2=end regex, $3=file
  start="$1"; end="$2"; f="$3"
  [ -f "$f" ] || return 0
  tmp="$f.tmp.$(date +%s)"
  awk '
    BEGIN{del=0}
    { if ($0 ~ start) {del=1}
      if (!del) print
      if ($0 ~ end && del==1) {del=0}
    }' start="$start" end="$end" "$f" > "$tmp" && mv "$tmp" "$f"
}

# ---------- detect package managers ----------
BREW_BIN=`command -v brew 2>/dev/null || echo ''`
PORT_BIN=`command -v port 2>/dev/null || echo ''`

brew_has() {
  [ -n "$BREW_BIN" ] || return 1
  brew list --formula 2>/dev/null | awk -v p="$1" '($0==p){f=1} END{exit(!f)}'
}
brew_has_cask() {
  [ -n "$BREW_BIN" ] || return 1
  brew list --cask 2>/dev/null | awk -v p="$1" '($0==p){f=1} END{exit(!f)}'
}
port_has() {
  [ -n "$PORT_BIN" ] || return 1
  "$PORT_BIN" -q installed "$1" >/dev/null 2>&1
}

# ---------- collect candidates ----------
CAND_PDK_DIRS=""
CAND_MAGICRCS=""
CAND_MAGIC_BINS=""

add_line_unique() {
  # $1=item, $2=list
  item="$1"; list="$2"
  echo "$list" | awk -v i="$item" '
    BEGIN{found=0}
    $0==i {found=1}
    {print}
    END{if(!found) print i}
  ' | sed '/^$/d'
}

collect_candidates() {
  info "Scanning for SKY130A and Magic…"
  bases="$HOME $HOME/eda $HOME/eda/pdks $HOME/.eda-bootstrap /opt/homebrew /usr/local /opt/local"
  for b in $bases; do
    [ -d "$b" ] || continue
    # find sky130A by *file* signature (preferred)
    for f in `find "$b" -type f -name sky130A.magicrc -path '*/sky130A/libs.tech/magic/*' 2>/dev/null`; do
      d1=`dirname "$f"`; d2=`dirname "$d1"`; d3=`dirname "$d2"`; sky=`dirname "$d3"`
      pdkroot=`dirname "$sky"`   # …/share/pdk
      cand="$s
