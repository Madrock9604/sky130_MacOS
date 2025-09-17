#!/usr/bin/env bash
# macOS SKY130 — Full Uninstaller (interactive, safe-by-default)
# ---------------------------------------------------------------
# Removes the SKY130A PDK tree, startup configs, and (optionally, with prompts)
# Homebrew *and* MacPorts installs of Magic, Xschem, ngspice, Netgen, KLayout,
# and XQuartz. It will ask before every major removal unless you pass -y.
#
# Examples:
#   bash uninstall.sh                # interactive (recommended)
#   bash uninstall.sh -y             # remove all major components without prompts
#   bash uninstall.sh --dry-run      # show what would be removed
#
# Notes:
# - This script does *not* remove Homebrew or MacPorts themselves; only packages.
# - Some MacPorts removals require sudo. We will prompt once if needed.

set -euo pipefail
IFS=$'
	'

info()  { printf "[1;34m[i][0m %s
" "$*"; }
ok()    { printf "[1;32m[✓][0m %s
" "$*"; }
warn()  { printf "[1;33m[!][0m %s
" "$*"; }
fail()  { printf "[1;31m[x][0m %s
" "$*"; exit 1; }

YES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '1,80p' "$0"; exit 0 ;;
    *) warn "Unknown arg: $1"; shift ;;
  esac
done

confirm() {
  local prompt="$1"
  if $YES; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " ans || true
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

run() {
  if $DRY_RUN; then info "DRY-RUN: $*"; else eval "$*"; fi
}

# Detect package managers
BREW_BIN="$(command -v brew || true)"
PORT_BIN="$(command -v port || true)"

# ---------- PDK detection (handles both $PDK_PREFIX/share/pdk and custom paths) ----------
DEFAULT_PDK_PREFIX="$HOME/eda/pdks"
DEFAULT_PDK_ROOT="$DEFAULT_PDK_PREFIX/share/pdk"
PDK_ROOT_ENV="${PDK_ROOT:-}"
PDK_PREFIX_ENV="${PDK_PREFIX:-}"

find_pdk_root() {
  # 1) If env points to a valid sky130A
  if [ -n "$PDK_ROOT_ENV" ] && [ -f "$PDK_ROOT_ENV/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf "%s" "$PDK_ROOT_ENV"; return 0
  fi
  # 2) Derive from PDK_PREFIX
  local cand="${PDK_PREFIX_ENV:-$DEFAULT_PDK_PREFIX}/share/pdk"
  if [ -f "$cand/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf "%s" "$cand"; return 0
  fi
  # 3) Search common prefixes
  local found
  for base in "$DEFAULT_PDK_PREFIX" "$HOME/eda" "$HOME/.eda-bootstrap" \
              /opt/homebrew/share/pdk /usr/local/share/pdk; do
    found="$(find "$base" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || true)"
    if [ -n "$found" ]; then
      local pdk_root
      pdk_root="$(dirname "$(dirname "$(dirname "$found")") )"
      printf "%s" "$(dirname "$pdk_root")"
      return 0
    fi
  done
  printf ""
}

PDK_ROOT_DETECTED="$(find_pdk_root)"
PDK_ROOT="${PDK_ROOT_DETECTED:-$DEFAULT_PDK_ROOT}"
if [[ "$PDK_ROOT" == */share/pdk ]]; then
  PDK_PREFIX="${PDK_ROOT%/share/pdk}"
else
  PDK_PREFIX="${PDK_PREFIX_ENV:-$DEFAULT_PDK_PREFIX}"
fi

info "Detected PDK_ROOT: $PDK_ROOT"
info "Detected PDK_PREFIX: $PDK_PREFIX"

# ---------- Helpers ----------
rmrf() {
  local target="$1"
  if [ ! -e "$target" ]; then warn "Not found: $target"; return 0; fi
  if $DRY_RUN; then info "DRY-RUN rm -rf $target"; else rm -rf "$target"; fi
}

sed_delete_block() {
  # delete lines between two markers (inclusive) in file
  local start="$1" end="$2" file="$3"
  [ -f "$file" ] || return 0
  cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  if sed --version >/dev/null 2>&1; then
    sed -i "/$start/,/$end/d" "$file"
  else
    sed -i '' "/$start/,/$end/d" "$file"
  fi
}

brew_installed_formula() { [ -n "$BREW_BIN" ] && brew list --formula 2>/dev/null | grep -qx "$1"; }
brew_installed_cask()    { [ -n "$BREW_BIN" ] && brew list --cask    2>/dev/null | grep -qx "$1"; }

brew_try_uninstall() {
  local pkg="$1" kind="$2"  # kind: formula|cask
  if [ -z "$BREW_BIN" ]; then return 0; fi
  if [ "$kind" = formula ] && brew_installed_formula "$pkg"; then
    run "brew uninstall --ignore-dependencies '$pkg' || true"
    ok "Homebrew formula removed: $pkg"
  elif [ "$kind" = cask ] && brew_installed_cask "$pkg"; then
    run "brew uninstall --cask '$pkg' || true"
    ok "Homebrew cask removed: $pkg"
  fi
}

port_installed() { [ -n "$PORT_BIN" ] && "$PORT_BIN" -q installed "$1" >/dev/null 2>&1; }

port_try_uninstall() {
  local pkg="$1"
  [ -z "$PORT_BIN" ] && return 0
  if port_installed "$pkg"; then
    if command -v sudo >/dev/null 2>&1; then
      run "sudo -n true 2>/dev/null || sudo -v"  # prompt once
      run "sudo port -N uninstall '$pkg' || true"
    else
      run "port -N uninstall '$pkg' || true"
    fi
    ok "MacPorts port removed: $pkg"
  fi
}

# ---------- 1) Remove SKY130 PDK ----------
if [ -d "$PDK_ROOT/sky130A" ]; then
  if confirm "Remove SKY130A PDK at $PDK_ROOT/sky130A?"; then
    rmrf "$PDK_ROOT/sky130A"
    ok "Removed SKY130A PDK."
  else
    warn "Kept SKY130A PDK."
  fi
else
  warn "No SKY130A PDK directory found under $PDK_ROOT"
fi

# ---------- 2) Clean user configs (Magic/Xschem env) ----------
if confirm "Remove Magic startup files we created (∼/.magicrc and rc_wrapper)?"; then
  rmrf "$HOME/.config/sky130/rc_wrapper.tcl"
  if [ -f "$HOME/.magicrc" ] && grep -q 'SKY130A magicrc not found. Check PDK_ROOT.' "$HOME/.magicrc" 2>/dev/null; then
    rmrf "$HOME/.magicrc"
  else
    warn "~/.magicrc not removed (custom or not ours)."
  fi
  ok "Cleaned Magic startup files."
else
  warn "Kept Magic startup files."
fi

# Remove SKY130 env block from common shells
for zfile in "$HOME/.zprofile" "$HOME/.zshrc"; do
  if [ -f "$zfile" ] && grep -q 'BEGIN SKY130 ENV' "$zfile" 2>/dev/null; then
    if confirm "Strip SKY130 env block from $(basename "$zfile")?"; then
      sed_delete_block 'BEGIN SKY130 ENV' 'END SKY130 ENV' "$zfile"
      ok "Edited $zfile"
    else
      warn "Kept env block in $zfile"
    fi
  fi
done

# ---------- 3) Uninstall Homebrew packages (asks per major tool) ----------
if [ -n "$BREW_BIN" ]; then
  info "Checking Homebrew packages…"
  # Some setups use 'magic', others 'magic-netgen'; handle both.
  if brew_installed_formula magic || brew_installed_formula magic-netgen; then
    if confirm "Uninstall Magic (Homebrew)?"; then
      brew_try_uninstall magic formula
      brew_try_uninstall magic-netgen formula
    fi
  fi
  if brew_installed_formula netgen; then
    if confirm "Uninstall Netgen (Homebrew)?"; then
      brew_try_uninstall netgen formula
    fi
  fi
  if brew_installed_formula xschem; then
    if confirm "Uninstall Xschem (Homebrew)?"; then
      brew_try_uninstall xschem formula
    fi
  fi
  if brew_installed_formula ngspice; then
    if confirm "Uninstall ngspice (Homebrew)?"; then
      brew_try_uninstall ngspice formula
    fi
  fi
  # KLayout is sometimes a formula, sometimes a cask
  if brew_installed_formula klayout || brew_installed_cask klayout; then
    if confirm "Uninstall KLayout (Homebrew)?"; then
      brew_try_uninstall klayout formula
      brew_try_uninstall klayout cask
    fi
  fi
  if brew_installed_cask xquartz; then
    if confirm "Uninstall XQuartz (Homebrew cask)?"; then
      brew_try_uninstall xquartz cask
    fi
  fi
else
  warn "Homebrew not detected; skipping brew removals."
fi

# ---------- 4) Uninstall MacPorts packages (asks per major tool) ----------
if [ -n "$PORT_BIN" ]; then
  info "Checking MacPorts ports…"
  for portname in magic netgen xschem ngspice klayout open_pdks openpdks open_pdks-sky130; do
    if port_installed "$portname" && confirm "Uninstall $portname (MacPorts)?"; then
      port_try_uninstall "$portname"
    fi
  done
  # XQuartz equivalent in MacPorts is usually xorg-server (rarely used on recent macOS)
  if port_installed xorg-server && confirm "Uninstall xorg-server (MacPorts)?"; then
    port_try_uninstall xorg-server
  fi
else
  warn "MacPorts not detected; skipping MacPorts removals."
fi

# ---------- 5) Remove source trees / caches ----------
if confirm "Remove source/cache directories (~/eda/src/open_pdks, ~/.eda-bootstrap)?"; then
  rmrf "$HOME/eda/src/open_pdks"
  rmrf "$HOME/.eda-bootstrap"
  ok "Removed source/cache directories."
else
  warn "Kept source/cache directories."
fi

ok "Uninstall flow complete. Open a new terminal to use a clean environment."

cat <<'POSTHINT'
Hints:
- If Magic still auto-loads a tech, check for a project-local .magicrc in your design folders.
- To fully clear env in *this* shell session: unset PDK_ROOT PDK_PREFIX SKYWATER_PDK OPEN_PDKS_ROOT MAGTYPE
- You can reinstall later with scripts/install-mac.sh
POSTHINT
