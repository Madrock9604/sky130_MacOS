#!/bin/sh
# macOS SKY130 — Full Uninstaller (POSIX sh, interactive)
# -------------------------------------------------------
# Removes the SKY130A PDK tree, startup configs, and (optionally) Homebrew/MacPorts
# packages for Magic, Netgen, Xschem, ngspice, KLayout, and XQuartz.
# Prompts before each major removal unless -y is provided.
# Now proactively prompts for admin rights when MacPorts removals need them.
#
# Usage:
#   sh uninstall.sh                # interactive
#   sh uninstall.sh -y             # remove all without prompts
#   sh uninstall.sh --dry-run      # show actions only

set -eu

YES=false
DRY=false

# --- arg parse ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0 ;;
    *) printf '%s
' "[!] Unknown arg: $1" ;;
  esac
  shift
done

confirm() {
  prompt="$1"
  if [ "$YES" = true ]; then return 0; fi
  printf '%s [y/N]: ' "$prompt"
  read ans || ans=""
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

run()  { [ "$DRY" = true ] && printf 'DRY-RUN: %s
' "$*" || sh -c "$*"; }
rmrf() { [ -e "$1" ] || { printf '[i] Not found: %s
' "$1"; return 0; }
         [ "$DRY" = true ] && printf 'DRY-RUN rm -rf %s
' "$1" || rm -rf "$1"; }

# --- detect package managers ---
BREW_BIN=$(command -v brew 2>/dev/null || printf '')
PORT_BIN=$(command -v port 2>/dev/null || printf '')

# --- sudo helpers (for MacPorts) ---
ensure_sudo() {
  if [ -n "$SUDO_ASKPASS" ]; then
    sudo -A -v || { printf '%s
' "[x] Could not obtain admin privileges (sudo)."; exit 1; }
  else
    sudo -v    || { printf '%s
' "[x] Could not obtain admin privileges (sudo)."; exit 1; }
  fi
}

sudo_ticket_valid() { sudo -n true 2>/dev/null; }

# Determine MacPorts prefix (defaults to /opt/local)
PORT_PREFIX="/opt/local"
if [ -n "$PORT_BIN" ]; then
  PORT_PREFIX=$($PORT_BIN -q prefix 2>/dev/null || printf '/opt/local')
fi

macports_needs_admin() {
  # If we cannot write to the prefix, we need sudo
  [ -w "$PORT_PREFIX" ] && [ -w "$PORT_PREFIX/var/macports" ] || return 0
  return 1
}

# --- brew helpers ---
brew_formula_installed() { [ -n "$BREW_BIN" ] && brew list --formula 2>/dev/null | grep -qx "$1"; }
brew_cask_installed()    { [ -n "$BREW_BIN" ] && brew list --cask    2>/dev/null | grep -qx "$1"; }

brew_uninstall_formula() {
  pkg="$1"
  brew_formula_installed "$pkg" || return 0
  run "brew uninstall --ignore-dependencies '$pkg' || true"
}

brew_uninstall_cask() {
  pkg="$1"
  brew_cask_installed "$pkg" || return 0
  run "brew uninstall --cask '$pkg' || true"
}

# --- ports helpers ---
port_installed() { [ -n "$PORT_BIN" ] && "$PORT_BIN" -q installed "$1" >/dev/null 2>&1; }

port_uninstall() {
  pkg="$1"
  port_installed "$pkg" || return 0
  if macports_needs_admin || ! sudo_ticket_valid; then
    printf '%s
' "[i] Admin privileges required to modify MacPorts. You'll be prompted once."
    ensure_sudo
  fi
  run "sudo ${PORT_BIN:-port} -N uninstall '$pkg' || true"
}

# --- detect PDK_ROOT ---
DEFAULT_PDK_PREFIX="$HOME/eda/pdks"
DEFAULT_PDK_ROOT="$DEFAULT_PDK_PREFIX/share/pdk"
PDK_ROOT_ENV=${PDK_ROOT-}
PDK_PREFIX_ENV=${PDK_PREFIX-}

find_pdk_root() {
  # 1) env-specified
  if [ -n "$PDK_ROOT_ENV" ] && [ -f "$PDK_ROOT_ENV/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf '%s' "$PDK_ROOT_ENV"; return 0
  fi
  # 2) derived from prefix
  cand="${PDK_PREFIX_ENV:-$DEFAULT_PDK_PREFIX}/share/pdk"
  if [ -f "$cand/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf '%s' "$cand"; return 0
  fi
  # 3) search common locations
  for base in "$DEFAULT_PDK_PREFIX" "$HOME/eda" "$HOME/.eda-bootstrap" /opt/homebrew/share/pdk /usr/local/share/pdk; do
    [ -d "$base" ] || continue
    found=$(find "$base" -type f -name sky130A.magicrc -path '*/sky130A/libs.tech/magic/*' -print -quit 2>/dev/null || printf '')
    if [ -n "$found" ]; then
      d1=$(dirname "$found"); d2=$(dirname "$d1"); d3=$(dirname "$d2"); sky=$(dirname "$d3")
      printf '%s' "$(dirname "$sky")"
      return 0
    fi
  done
  printf '%s' ""
}

PDK_ROOT_DETECTED=$(find_pdk_root)
if [ -n "$PDK_ROOT_DETECTED" ]; then
  PDK_ROOT="$PDK_ROOT_DETECTED"
else
  PDK_ROOT="$DEFAULT_PDK_ROOT"
fi
case "$PDK_ROOT" in
  */share/pdk) PDK_PREFIX=$(dirname "$PDK_ROOT") ;;
  *)           PDK_PREFIX="${PDK_PREFIX_ENV:-$DEFAULT_PDK_PREFIX}" ;;
esac

printf '%s
' "[i] Using PDK_ROOT=$PDK_ROOT"
printf '%s
' "[i] Using PDK_PREFIX=$PDK_PREFIX"

# --- 1) Remove SKY130 PDK ---
if [ -d "$PDK_ROOT/sky130A" ]; then
  if confirm "Remove SKY130A PDK at $PDK_ROOT/sky130A?"; then
    rmrf "$PDK_ROOT/sky130A"
    printf '%s
' "[✓] Removed SKY130A PDK"
  else
    printf '%s
' "[!] Kept SKY130A PDK"
  fi
else
  printf '%s
' "[!] No SKY130A under $PDK_ROOT"
fi

# --- 2) Clean Magic configs ---
if confirm "Remove Magic startup files we created (~/.magicrc and rc_wrapper)?"; then
  rmrf "$HOME/.config/sky130/rc_wrapper.tcl"
  if [ -f "$HOME/.magicrc" ] && grep -q 'SKY130A magicrc not found. Check PDK_ROOT.' "$HOME/.magicrc" 2>/dev/null; then
    rmrf "$HOME/.magicrc"
  else
    printf '%s
' "[!] ~/.magicrc looks custom; left in place"
  fi
fi

# --- 3) Remove env block from shells ---
strip_env() {
  f="$1"
  [ -f "$f" ] || return 0
  if grep -q 'BEGIN SKY130 ENV' "$f" 2>/dev/null; then
    if confirm "Strip SKY130 env block from $(basename "$f")?"; then
      cp "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
      sed -i '' -e '/BEGIN SKY130 ENV/,/END SKY130 ENV/d' "$f"
      printf '%s
' "[✓] Edited $f"
    fi
  fi
}
strip_env "$HOME/.zprofile"
strip_env "$HOME/.zshrc"

# --- 4) Homebrew packages ---
if [ -n "$BREW_BIN" ]; then
  printf '%s
' "[i] Homebrew detected: $(brew --prefix 2>/dev/null || printf '')"
  if brew_formula_installed magic || brew_formula_installed magic-netgen; then
    if confirm "Uninstall Magic (Homebrew)?"; then
      brew_uninstall_formula magic
      brew_uninstall_formula magic-netgen
    fi
  fi
  if brew_formula_installed netgen && confirm "Uninstall Netgen (Homebrew)?"; then
    brew_uninstall_formula netgen
  fi
  if brew_formula_installed xschem && confirm "Uninstall Xschem (Homebrew)?"; then
    brew_uninstall_formula xschem
  fi
  if brew_formula_installed ngspice && confirm "Uninstall ngspice (Homebrew)?"; then
    brew_uninstall_formula ngspice
  fi
  if brew_formula_installed klayout || brew_cask_installed klayout; then
    if confirm "Uninstall KLayout (Homebrew)?"; then
      brew_uninstall_formula klayout
      brew_uninstall_cask klayout
    fi
  fi
  if brew_cask_installed xquartz && confirm "Uninstall XQuartz (Homebrew cask)?"; then
    brew_uninstall_cask xquartz
  fi
else
  printf '%s
' "[!] Homebrew not detected; skipping brew removals"
fi

# --- 5) MacPorts packages (with sudo prompt when required) ---
if [ -n "$PORT_BIN" ]; then
  printf '%s
' "[i] MacPorts detected: $PORT_BIN (prefix: $PORT_PREFIX)"
  for p in magic netgen xschem ngspice klayout open_pdks openpdks open_pdks-sky130; do
    if port_installed "$p" && confirm "Uninstall $p (MacPorts)?"; then
      port_uninstall "$p"
    fi
  done
  if port_installed xorg-server && confirm "Uninstall xorg-server (MacPorts)?"; then
    port_uninstall xorg-server
  fi
else
  printf '%s
' "[!] MacPorts not detected; skipping ports removals"
fi

# --- 6) Remove sources / caches ---
if confirm "Remove source/cache directories (~/eda/src/open_pdks, ~/.eda-bootstrap)?"; then
  rmrf "$HOME/eda/src/open_pdks"
  rmrf "$HOME/.eda-bootstrap"
fi

printf '%s
' "[✓] Uninstall flow complete. Open a new terminal for a clean env."
printf '%s
' "Hints: If Magic still loads a tech, check for project-local .magicrc files."
