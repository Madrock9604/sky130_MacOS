cat > /tmp/sky130-uninstall.sh <<'SH'
#!/bin/sh
# macOS SKY130 — Full Uninstaller (POSIX sh, interactive)
# Removes SKY130A PDK, startup configs, and (optionally) Homebrew/MacPorts EDA tools.
set -eu

YES=false
DRY=false

# --- args ---
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '1,120p' "$0"; exit 0 ;;
    *) printf '[!] Unknown arg: %s\n' "$1" ;;
  esac
  shift
done

confirm() {
  [ "$YES" = true ] && return 0
  printf '%s [y/N]: ' "$1"
  read ans || ans=""
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

run()  { [ "$DRY" = true ] && printf 'DRY-RUN: %s\n' "$*" || sh -c "$*"; }
rmrf() { [ -e "$1" ] || { printf '[i] Not found: %s\n' "$1"; return 0; }
         [ "$DRY" = true ] && printf 'DRY-RUN rm -rf %s\n' "$1" || rm -rf "$1"; }

BREW=$(command -v brew 2>/dev/null || printf '')
PORT=$(command -v port 2>/dev/null || printf '')

brew_f_installed() { [ -n "$BREW" ] && brew list --formula 2>/dev/null | grep -qx "$1"; }
brew_c_installed() { [ -n "$BREW" ] && brew list --cask    2>/dev/null | grep -qx "$1"; }
brew_uninst_f()    { brew_f_installed "$1" && run "brew uninstall --ignore-dependencies '$1' || true"; }
brew_uninst_c()    { brew_c_installed "$1" && run "brew uninstall --cask '$1' || true"; }

port_installed()   { [ -n "$PORT" ] && "$PORT" -q installed "$1" >/dev/null 2>&1; }
port_uninstall()   {
  port_installed "$1" || return 0
  if command -v sudo >/dev/null 2>&1; then run "sudo -n true 2>/dev/null || sudo -v"; fi
  run "${PORT:-port} -N uninstall '$1' || true"
}

# --- detect PDK_ROOT ---
DEF_PREFIX="$HOME/eda/pdks"; DEF_ROOT="$DEF_PREFIX/share/pdk"
PDK_ROOT_ENV=${PDK_ROOT-}; PDK_PREFIX_ENV=${PDK_PREFIX-}

find_pdk_root() {
  if [ -n "$PDK_ROOT_ENV" ] && [ -f "$PDK_ROOT_ENV/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf '%s' "$PDK_ROOT_ENV"; return
  fi
  cand="${PDK_PREFIX_ENV:-$DEF_PREFIX}/share/pdk"
  if [ -f "$cand/sky130A/libs.tech/magic/sky130A.magicrc" ]; then printf '%s' "$cand"; return; fi
  for base in "$DEF_PREFIX" "$HOME/eda" "$HOME/.eda-bootstrap" /opt/homebrew/share/pdk /usr/local/share/pdk; do
    [ -d "$base" ] || continue
    found=$(find "$base" -type f -name sky130A.magicrc -path '*/sky130A/libs.tech/magic/*' -print -quit 2>/dev/null || printf '')
    if [ -n "$found" ]; then d1=$(dirname "$found"); d2=$(dirname "$d1"); d3=$(dirname "$d2"); sky=$(dirname "$d3"); printf '%s' "$(dirname "$sky")"; return; fi
  done
  printf '%s' ""
}

PDK_ROOT_DET=$(find_pdk_root)
[ -n "$PDK_ROOT_DET" ] || PDK_ROOT_DET="$DEF_ROOT"
PDK_ROOT="$PDK_ROOT_DET"
case "$PDK_ROOT" in */share/pdk) PDK_PREFIX=$(dirname "$PDK_ROOT") ;; *) PDK_PREFIX="${PDK_PREFIX_ENV:-$DEF_PREFIX}" ;; esac
printf '[i] Using PDK_ROOT=%s\n[i] Using PDK_PREFIX=%s\n' "$PDK_ROOT" "$PDK_PREFIX"

# --- 1) PDK ---
if [ -d "$PDK_ROOT/sky130A" ]; then
  if confirm "Remove SKY130A PDK at $PDK_ROOT/sky130A?"; then rmrf "$PDK_ROOT/sky130A"; printf '[✓] Removed SKY130A PDK\n'
  else printf '[!] Kept SKY130A PDK\n'; fi
else printf '[!] No SKY130A under %s\n' "$PDK_ROOT"; fi

# --- 2) Magic startup files ---
if confirm "Remove Magic startup files we created (~/.magicrc and rc_wrapper)?"; then
  rmrf "$HOME/.config/sky130/rc_wrapper.tcl"
  if [ -f "$HOME/.magicrc" ] && grep -q 'SKY130A magicrc not found. Check PDK_ROOT.' "$HOME/.magicrc" 2>/dev/null; then
    rmrf "$HOME/.magicrc"
  else printf '[!] ~/.magicrc looks custom; left in place\n'; fi
fi

# --- 3) Env blocks ---
strip_env() {
  f="$1"; [ -f "$f" ] || return 0
  if grep -q 'BEGIN SKY130 ENV' "$f" 2>/dev/null; then
    if confirm "Strip SKY130 env block from $(basename "$f")?"; then
      cp "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
      sed -i '' -e '/BEGIN SKY130 ENV/,/END SKY130 ENV/d' "$f"
      printf '[✓] Edited %s\n' "$f"
    fi
  fi
}
strip_env "$HOME/.zprofile"; strip_env "$HOME/.zshrc"

# --- 4) Homebrew ---
if [ -n "$BREW" ]; then
  printf '[i] Homebrew detected: %s\n' "$(brew --prefix 2>/dev/null || printf '')"
  if ( brew_f_installed magic || brew_f_installed magic-netgen ) && confirm "Uninstall Magic (Homebrew)?"; then
    brew_uninst_f magic; brew_uninst_f magic-netgen; fi
  if brew_f_installed netgen && confirm "Uninstall Netgen (Homebrew)?"; then brew_uninst_f netgen; fi
  if brew_f_installed xschem && confirm "Uninstall Xschem (Homebrew)?"; then brew_uninst_f xschem; fi
  if brew_f_installed ngspice && confirm "Uninstall ngspice (Homebrew)?"; then brew_uninst_f ngspice; fi
  if ( brew_f_installed klayout || brew_c_installed klayout ) && confirm "Uninstall KLayout (Homebrew)?"; then
    brew_uninst_f klayout; brew_uninst_c klayout; fi
  if brew_c_installed xquartz && confirm "Uninstall XQuartz (Homebrew cask)?"; then brew_uninst_c xquartz; fi
else
  printf '[!] Homebrew not detected; skipping brew removals\n'
fi

# --- 5) MacPorts ---
if [ -n "$PORT" ]; then
  printf '[i] MacPorts detected: %s\n' "$PORT"
  for p in magic netgen xschem ngspice klayout open_pdks openpdks open_pdks-sky130; do
    if port_installed "$p" && confirm "Uninstall $p (MacPorts)?"; then port_uninstall "$p"; fi
  done
  if port_installed xorg-server && confirm "Uninstall xorg-server (MacPorts)?"; then port_uninstall xorg-server; fi
else
  printf '[!] MacPorts not detected; skipping ports removals\n'
fi

# --- 6) Sources/caches ---
if confirm "Remove source/cache directories (~/eda/src/open_pdks, ~/.eda-bootstrap)?"; then
  rmrf "$HOME/eda/src/open_pdks"; rmrf "$HOME/.eda-bootstrap"
fi

printf '[✓] Uninstall complete. Open a new terminal for a clean environment.\n'
printf 'Hints: If Magic still loads a tech, check for project-local .magicrc files.\n'
SH

chmod +x /tmp/sky130-uninstall.sh
sh -n /tmp/sky130-uninstall.sh && sh /tmp/sky130-uninstall.sh
