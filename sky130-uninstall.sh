#!/bin/sh
# SKY130 macOS — Aggressive Uninstaller (POSIX sh)
# Removes SKY130A PDK + Magic (brew/ports/user-built) and configs/launchers so
# Magic no longer auto-loads sky130A. Scans system paths like /opt/pdk.

set -eu

YES=false
DRY=false
EXTRA_DIRS=""

# ---------- args ----------
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    --scan) shift || true; [ -n "${1-}" ] || { echo "[x] --scan requires a path" >&2; exit 1; }; EXTRA_DIRS="${EXTRA_DIRS}\n$1" ;;
    -h|--help) sed -n '1,200p' "$0"; exit 0 ;;
    *) printf '[!] Unknown arg: %s\n' "$1" ;;
  esac
  shift
done

# ---------- helpers ----------
info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31m[x]\033[0m %s\n' "$*"; exit 1; }

confirm(){ prompt="$1"; if [ "$YES" = true ]; then return 0; fi; printf '%s [y/N]: ' "$prompt"; read ans || ans=""; [ "$ans" = "y" ] || [ "$ans" = "Y" ]; }

run(){ if [ "$DRY" = true ]; then printf 'DRY-RUN: %s\n' "$*"; else sh -c "$*"; fi; }

# remove with sudo fallback if needed
HAS_TTY=0; [ -t 1 ] && HAS_TTY=1
run_admin(){ _cmd="$1"; if [ "$DRY" = true ]; then [ "$HAS_TTY" -eq 1 ] && printf 'DRY-RUN sudo %s\n' "$_cmd" || printf 'DRY-RUN (GUI sudo) %s\n' "$_cmd"; return 0; fi; if [ "$HAS_TTY" -eq 1 ]; then sudo -n true 2>/dev/null || sudo -v || fail "Admin privileges required"; sh -c "sudo $_cmd"; else _esc=`printf %s "$_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g'`; /usr/bin/osascript -e "do shell script \"$_esc\" with administrator privileges"; fi; }

rmrf_any(){
  tgt="$1"
  if [ ! -e "$tgt" ]; then info "Not found: $tgt"; return 0; fi
  if [ "$DRY" = true ]; then printf 'DRY-RUN rm -rf %s\n' "$tgt"; return 0; fi
  rm -rf -- "$tgt" 2>/dev/null || run_admin "rm -rf -- '$tgt'"
  ok "Removed: $tgt"
}

# delete BEGIN..END block safely (no sed -i dependency)
delete_block_in_file(){ start="$1"; end="$2"; f="$3"; [ -f "$f" ] || return 0; tmp="$f.tmp.$(date +%s)"; awk 'BEGIN{del=0}{if($0~start){del=1} if(!del)print; if($0~end&&del==1){del=0}}' start="$start" end="$end" "$f" > "$tmp" && mv "$tmp" "$f"; }

# ---------- detect package managers ----------
BREW_BIN=`command -v brew 2>/dev/null || echo ''`
PORT_BIN=`command -v port 2>/dev/null || echo ''`
brew_has(){ [ -n "$BREW_BIN" ] || return 1; brew list --formula 2>/dev/null | awk -v p="$1" '($0==p){f=1} END{exit(!f)}'; }
brew_has_cask(){ [ -n "$BREW_BIN" ] || return 1; brew list --cask 2>/dev/null | awk -v p="$1" '($0==p){f=1} END{exit(!f)}'; }
port_has(){ [ -n "$PORT_BIN" ] || return 1; "$PORT_BIN" -q installed "$1" >/dev/null 2>&1; }

# ---------- build scan set ----------
add_unique(){ item="$1"; list="$2"; echo "$list" | awk -v i="$item" 'BEGIN{f=0}$0==i{f=1}{print}END{if(!f)print i}' | sed '/^$/d'; }
SCAN_BASES=""
append_base(){ d="$1"; [ -n "$d" ] && [ -d "$d" ] && SCAN_BASES=`add_unique "$d" "$SCAN_BASES"` || true; }

# defaults + system paths + where you are + git root + extras
append_base "$HOME"
append_base "$HOME/eda"
append_base "$HOME/eda/pdks"
append_base "$HOME/.eda-bootstrap"
append_base "/opt"
append_base "/opt/pdk"
append_base "/opt/pdk/share/pdk"
append_base "/opt/homebrew"
append_base "/usr/local"
append_base "/opt/local"
append_base "/Applications"
append_base "$PWD"
GITROOT=`command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel 2>/dev/null || echo ''`; append_base "$GITROOT"
if [ -n "$EXTRA_DIRS" ]; then for x in $EXTRA_DIRS; do append_base "$x"; done; fi
if [ -n "${EXTRA_SCAN_DIRS-}" ]; then IFS_SAVE=$IFS; IFS=":"; for x in $EXTRA_SCAN_DIRS; do IFS="$IFS_SAVE"; append_base "$x"; IFS=":"; done; IFS="$IFS_SAVE"; fi

# ---------- collect candidates ----------
CAND_PDK_DIRS=""
CAND_MAGICRCS=""
CAND_MAGIC_BINS=""
CAND_WRAPPERS=""

collect(){
  info "Scanning for SKY130A PDK, Magic, and rc/wrappers…"
  for b in $SCAN_BASES; do
    [ -d "$b" ] || continue
    # sky130A by signature file
    for f in `find "$b" -type f -name sky130A.magicrc -path '*/sky130A/libs.tech/magic/*' 2>/dev/null`; do
      d1=`dirname "$f"`; d2=`dirname "$d1"`; d3=`dirname "$d2"`; sky=`dirname "$d3"`
      CAND_PDK_DIRS=`add_unique "$sky" "$CAND_PDK_DIRS"`
    done
    # sky130A fallback tree pattern
    for d in `find "$b" -type d -name sky130A -path '*/pdk/sky130A' 2>/dev/null`; do
      CAND_PDK_DIRS=`add_unique "$d" "$CAND_PDK_DIRS"`
    done
    # .magicrc / magicrc that reference sky130A
    for f in `find "$b" -type f \( -name .magicrc -o -name magicrc \) 2>/dev/null`; do
      grep 'sky130A' "$f" >/dev/null 2>&1 && CAND_MAGICRCS=`add_unique "$f" "$CAND_MAGICRCS"`
    done
    # magic binaries (including app bundles)
    for m in `find "$b" -type f -perm -111 \( -name magic -o -name Magic -o -name magic\* \) 2>/dev/null`; do
      CAND_MAGIC_BINS=`add_unique "$m" "$CAND_MAGIC_BINS"`
      # wrapper scripts that hardcode sky130A rc
      if head -n1 "$m" 2>/dev/null | grep -q '^#!'; then
        grep -q 'sky130A\.magicrc' "$m" 2>/dev/null && CAND_WRAPPERS=`add_unique "$m" "$CAND_WRAPPERS"`
      fi
    done
  done
  # PATH too
  if command -v magic >/dev/null 2>&1; then CAND_MAGIC_BINS=`add_unique "$(command -v magic)" "$CAND_MAGIC_BINS"`; fi
}

# ---------- remove PDK trees ----------
remove_pdks(){
  if [ -z "$CAND_PDK_DIRS" ]; then warn "No sky130A directories found."; return 0; fi
  info "Found these sky130A directories:"; echo "$CAND_PDK_DIRS" | sed 's/^/  - /'
  if confirm "Delete ALL listed sky130A directories?"; then
    for d in $CAND_PDK_DIRS; do rmrf_any "$d"; done
  else warn "Kept sky130A directories."; fi
}

# ---------- uninstall Magic + tools ----------
remove_magic(){
  if [ -n "$BREW_BIN" ]; then
    info "Checking Homebrew packages…"
    if brew_has magic || brew_has magic-netgen; then confirm "Uninstall Magic (Homebrew)?" && run "brew uninstall --ignore-dependencies magic magic-netgen || true"; fi
    if brew_has netgen && confirm "Uninstall Netgen (Homebrew)?" ; then run "brew uninstall --ignore-dependencies netgen || true"; fi
    if brew_has xschem && confirm "Uninstall Xschem (Homebrew)?"; then run "brew uninstall --ignore-dependencies xschem || true"; fi
    if brew_has ngspice && confirm "Uninstall ngspice (Homebrew)?"; then run "brew uninstall --ignore-dependencies ngspice || true"; fi
    if brew_has klayout || brew_has_cask klayout; then
      if confirm "Uninstall KLayout (Homebrew)?"; then run "brew uninstall --ignore-dependencies klayout || true"; run "brew uninstall --cask klayout || true"; fi
    fi
    if brew_has_cask xquartz && confirm "Uninstall XQuartz (Homebrew)?"; then run "brew uninstall --cask xquartz || true"; fi
  else warn "Homebrew not detected; skipping brew removals."; fi

  if [ -n "$PORT_BIN" ]; then
    info "Checking MacPorts ports…"
    for p in magic netgen xschem ngspice klayout open_pdks openpdks open_pdks-sky130; do
      if port_has "$p" && confirm "Uninstall $p (MacPorts)?"; then run_admin "${PORT_BIN:-/opt/local/bin/port} -N uninstall '$p' || true"; fi
    done
    if port_has xorg-server && confirm "Uninstall xorg-server (MacPorts)?"; then run_admin "${PORT_BIN:-/opt/local/bin/port} -N uninstall xorg-server || true"; fi
  else warn "MacPorts not detected; skipping ports removals."; fi

  # user-built Magic under ~/eda/tools (from installer)
  for m in $CAND_MAGIC_BINS; do
    case "$m" in "$HOME/eda/tools"/*) base="$HOME/eda/tools"; [ -d "$base" ] && confirm "Remove user-built Magic directory $base ?" && rmrf_any "$base" ;; esac
  done
}

# ---------- remove wrappers that force sky130A rc ----------
remove_wrappers(){
  [ -z "$CAND_WRAPPERS" ] && return 0
  info "Wrappers that hardcode sky130A rc:"; echo "$CAND_WRAPPERS" | sed 's/^/  - /'
  if confirm "Backup and remove ALL listed wrappers?"; then
    for w in $CAND_WRAPPERS; do ts=`date +%Y%m%d%H%M%S`; run "cp '$w' '$w.bak.$ts'"; rmrf_any "$w"; done
  fi
}

# ---------- clean configs ----------
clean_configs(){
  rmrf_any "$HOME/.config/sky130/rc_wrapper.tcl"
  if [ -f "$HOME/.magicrc" ] && grep 'sky130A' "$HOME/.magicrc" >/dev/null 2>&1; then
    ts=`date +%Y%m%d%H%M%S`; confirm "~/.magicrc references sky130A. Backup and remove it?" && { run "cp '$HOME/.magicrc' '$HOME/.magicrc.bak.$ts'"; rmrf_any "$HOME/.magicrc"; }
  fi
  if [ -n "$CAND_MAGICRCS" ]; then
    info "rc files referencing sky130A:"; echo "$CAND_MAGICRCS" | sed 's/^/  - /'
    if confirm "Backup and remove ALL above rc files?"; then
      for f in $CAND_MAGICRCS; do ts=`date +%Y%m%d%H%M%S`; run "cp '$f' '$f.bak.$ts'"; rmrf_any "$f"; done
    fi
  fi
  for z in "$HOME/.zprofile" "$HOME/.zshrc"; do
    [ -f "$z" ] || continue
    ts=`date +%Y%m%d%H%M%S`; run "cp '$z' '$z.bak.$ts'"
    delete_block_in_file 'BEGIN SKY130 ENV' 'END SKY130 ENV' "$z"
    tmp="$z.tmp.$ts"
    awk '
      $0 ~ /^export[[:space:]]+PDK_ROOT=/ {next}
      $0 ~ /^export[[:space:]]+PDK_PREFIX=/ {next}
      $0 ~ /^export[[:space:]]+SKYWATER_PDK=/ {next}
      $0 ~ /^export[[:space:]]+OPEN_PDKS_ROOT=/ {next}
      $0 ~ /^export[[:space:]]+MAGTYPE=/ {next}
      $0 ~ /^export[[:space:]]+PATH=.*eda\/tools\/bin/ {next}
      {print}
    ' "$z" > "$tmp" && mv "$tmp" "$z"
    ok "Cleaned env in $(basename "$z") (backup: $z.bak.$ts)"
  done
}

# ---------- post check ----------
post_check(){
  info "Post-uninstall check"
  if command -v magic >/dev/null 2>&1; then
    echo "Magic still present at: $(command -v magic)"
    echo "Open Magic and run ':tech' — it should NOT say 'sky130A'."
  else ok "No 'magic' in PATH."; fi
}

# ---------- main ----------
collect
remove_pdks
remove_magic
remove_wrappers
clean_configs
post_check
ok "Uninstall complete. Open a new terminal for a clean environment."
