#!/bin/sh
# macOS SKY130 — Installer (POSIX sh)
# -----------------------------------
# Installs: Homebrew deps, XQuartz, Tcl/Tk, ngspice, (KLayout),
# ensures 'magic' exists (MacPorts if available, else build from source),
# then builds & installs open_pdks (sky130A) and wires env + Magic rc.
#
# Usage:
#   sh install-mac.sh
#   sh install-mac.sh -y            # noninteractive auto-yes
#   sh install-mac.sh --dry-run     # preview steps

set -eu

YES=false
DRY=false

# -------- arg parsing --------
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '1,200p' "$0"; exit 0 ;;
    *) printf '[!] Unknown arg: %s\n' "$1" ;;
  esac
  shift
done

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
  if [ "$DRY" = true ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    # shellcheck disable=SC2086
    sh -c "$*"
  fi
}

# -------- defaults / paths --------
PDK_PREFIX="${PDK_PREFIX:-$HOME/eda/pdks}"
PDK_ROOT_DEFAULT="$PDK_PREFIX/share/pdk"
MAGIC_PREFIX="${MAGIC_PREFIX:-$HOME/eda/tools}"
SRC_ROOT="${SRC_ROOT:-$HOME/eda/src}"

mkdir -p "$PDK_PREFIX" "$MAGIC_PREFIX" "$SRC_ROOT"

BREW_BIN=$(command -v brew 2>/dev/null || printf '')
PORT_BIN=$(command -v port 2>/dev/null || printf '')

# -------- step 0: Xcode CLT --------
ensure_xcode() {
  if ! xcode-select -p >/dev/null 2>&1; then
    info "Installing Xcode Command Line Tools…"
    run "xcode-select --install || true"
    warn "If a dialog appeared, finish it and re-run this script."
  fi
  ok "Xcode Command Line Tools present."
}

# -------- step 1: Homebrew (for deps) --------
ensure_homebrew() {
  if [ -z "$BREW_BIN" ]; then
    if confirm "Homebrew not found. Install Homebrew now?"; then
      run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      # shellenv
      if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
      BREW_BIN=$(command -v brew 2>/dev/null || printf '')
    else
      fail "Homebrew required for deps. Aborting."
    fi
  fi
  [ -n "$BREW_BIN" ] || fail "brew not available after installation."
  ok "Homebrew present at $(brew --prefix 2>/dev/null || printf 'unknown')."
}

# -------- step 2: install brew deps --------
install_brew_deps() {
  info "Installing build/runtime dependencies with Homebrew…"
  run "brew update"
  # Tcl/Tk + ngspice + gnu-sed (gsed used by some build steps) + cmake + standard GNU build tools
  run "brew install git automake autoconf libtool pkg-config gawk wget xz tcl-tk ngspice cmake gnu-sed"
  # XQuartz (X11) for Magic GUI
  run "brew install --cask xquartz || true"
  # KLayout (formula or cask depending on tap)
  run "brew install klayout || brew install --cask klayout || true"
  ok "Dependencies installed."
}

# -------- step 3: ensure MAGIC exists --------
install_magic_via_macports() {
  [ -n "$PORT_BIN" ] || return 1
  info "Installing Magic via MacPorts…"
  run "sudo -v"
  run "sudo port -N selfupdate || true"
  run "sudo port -N install magic"
  # Make sure /opt/local/bin is on PATH for this shell
  PATH="/opt/local/bin:$PATH"; export PATH
  ok "Magic installed via MacPorts."
  return 0
}

build_magic_from_source() {
  info "Building Magic from source into $MAGIC_PREFIX …"
  TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || printf '')"
  [ -n "$TCLTK_PREFIX" ] || warn "brew tcl-tk prefix not found; relying on system paths."
  CFLAGS_ADD=""
  LDFLAGS_ADD=""
  PKG_ADD=""
  if [ -n "$TCLTK_PREFIX" ]; then
    CFLAGS_ADD="-I$TCLTK_PREFIX/include"
    LDFLAGS_ADD="-L$TCLTK_PREFIX/lib"
    PKG_ADD="$TCLTK_PREFIX/lib/pkgconfig"
  fi

  mkdir -p "$SRC_ROOT"
  cd "$SRC_ROOT"
  if [ ! -d magic ]; then
    run "git clone https://github.com/RTimothyEdwards/magic.git"
  fi
  cd magic
  run "git fetch --all -q && git pull -q"
  # Configure
  if [ "$DRY" = false ]; then
    export CFLAGS="$CFLAGS_ADD ${CFLAGS-}"
    export LDFLAGS="$LDFLAGS_ADD ${LDFLAGS-}"
    export PKG_CONFIG_PATH="${PKG_ADD}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi
  run "./configure --prefix='$MAGIC_PREFIX' --with-x --with-opengl=no --disable-cairo \
       ${TCLTK_PREFIX:+--with-tcl='$TCLTK_PREFIX/lib' --with-tk='$TCLTK_PREFIX/lib' \
       --with-tclinclude='$TCLTK_PREFIX/include' --with-tkinclude='$TCLTK_PREFIX/include'}"
  # Build & install
  CORES="$(sysctl -n hw.ncpu 2>/dev/null || printf 2)"
  run "make -j$CORES"
  run "make install"
  # Make sure MAGIC is on PATH now
  PATH="$MAGIC_PREFIX/bin:$PATH"; export PATH
  ok "Magic built and installed to $MAGIC_PREFIX."
}

ensure_magic() {
  if command -v magic >/dev/null 2>&1; then
    ok "Magic already present: $(command -v magic)"
    return 0
  fi
  if [ -n "$PORT_BIN" ]; then
    if confirm "MacPorts detected. Install Magic via MacPorts?"; then
      install_magic_via_macports && return 0
      warn "MacPorts installation failed; will try source build."
    fi
  fi
  if confirm "Build Magic from source (no sudo, installs under $MAGIC_PREFIX)?"; then
    build_magic_from_source
  else
    fail "Magic is required by open_pdks. Aborting."
  fi
}

# -------- step 4: build & install open_pdks (sky130A) --------
build_open_pdks() {
  info "Building and installing open_pdks (sky130A)…"
  mkdir -p "$SRC_ROOT" "$PDK_PREFIX"
  cd "$SRC_ROOT"
  if [ ! -d open_pdks ]; then
    run "git clone https://github.com/RTimothyEdwards/open_pdks.git"
  fi
  cd open_pdks
  run "git fetch --all -q && git pull -q"
  # Clean (veryclean not always present)
  run "make clean || git clean -xfd || true"

  # Help builds find Homebrew Tcl/Tk if needed
  TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || printf '')"
  if [ -n "$TCLTK_PREFIX" ] && [ "$DRY" = false ]; then
    export LDFLAGS="-L$TCLTK_PREFIX/lib ${LDFLAGS-}"
    export CPPFLAGS="-I$TCLTK_PREFIX/include ${CPPFLAGS-}"
    export PKG_CONFIG_PATH="$TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi

  run "./configure --prefix='$PDK_PREFIX' --enable-sky130-pdk --with-sky130-variants=A"
  CORES="$(sysctl -n hw.ncpu 2>/dev/null || printf 2)"
  run "make -j$CORES"
  run "make -j$CORES install"
  ok "open_pdks installed under $PDK_PREFIX"
}

# -------- step 5: locate PDK_ROOT --------
find_pdk_root() {
  # 1) canonical path
  cand="$PDK_ROOT_DEFAULT"
  if [ -f "$cand/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf '%s' "$cand"; return 0
  fi
  # 2) search under PDK_PREFIX
  found=$(find "$PDK_PREFIX" -type f -path "*/sky130A/libs.tech/magic/sky130A.magicrc" -print -quit 2>/dev/null || printf '')
  if [ -z "$found" ]; then
    brew_share="$(brew --prefix 2>/dev/null)/share/pdk"
    found=$(find "$brew_share" -type f -path "*/sky130A/libs.tech/magic/sky130A.magicrc" -print -quit 2>/dev/null || printf '')
  fi
  if [ -n "$found" ]; then
    d1=$(dirname "$found"); d2=$(dirname "$d1"); d3=$(dirname "$d2"); sky=$(dirname "$d3")
    printf '%s' "$(dirname "$sky")"; return 0
  fi
  printf '%s' ""
}

# -------- step 6: persist env + magic rc --------
persist_env() {
  pdk_root="$1"
  zfile="$HOME/.zprofile"
  info "Persisting environment exports to $zfile …"
  if ! grep -q 'BEGIN SKY130 ENV' "$zfile" 2>/dev/null; then
    cat >> "$zfile" <<EOF

# ===== BEGIN SKY130 ENV (installed by sky130 installer) =====
export PDK_PREFIX="$PDK_PREFIX"
export PDK_ROOT="$pdk_root"
export SKYWATER_PDK="\$PDK_ROOT/sky130A"
export OPEN_PDKS_ROOT="\$PDK_PREFIX"
export MAGTYPE=mag
# Add user-installed Magic (if present)
export PATH="$MAGIC_PREFIX/bin:\$PATH"
# Homebrew Tcl/Tk flags (improve Magic/Xschem stability)
if command -v brew >/dev/null 2>&1; then
  BREW_TCLTK_PREFIX="\$(brew --prefix tcl-tk 2>/dev/null || true)"
  if [ -n "\$BREW_TCLTK_PREFIX" ]; then
    export LDFLAGS="-L\$BREW_TCLTK_PREFIX/lib\${LDFLAGS:+ \$LDFLAGS}"
    export CPPFLAGS="-I\$BREW_TCLTK_PREFIX/include\${CPPFLAGS:+ \$CPPFLAGS}"
    export PKG_CONFIG_PATH="\$BREW_TCLTK_PREFIX/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
  fi
fi
# ===== END SKY130 ENV =====
EOF
  fi
  ok "Environment exports appended. Open a new terminal to pick them up."
}

write_magic_rc() {
  info "Writing safe ~/.magicrc and removing stale wrapper…"
  run "rm -f \"$HOME/.config/sky130/rc_wrapper.tcl\" 2>/dev/null || true"
  cat > "$HOME/.magicrc" <<'EOF'
# Minimal, robust Magic startup for SKY130A
if { [info exists env(PDK_ROOT)] && \
     [file exists "$env(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc"] } {
    source "$env(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc"
} else {
    puts stderr "SKY130A magicrc not found. Check PDK_ROOT."
}
EOF
  ok "~/.magicrc configured."
}

# -------- step 7: smoke checks --------
smoke_checks() {
  pdk_root="$1"
  info "Verifying installed files…"
  [ -f "$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc" ] || fail "Missing sky130A.magicrc under $pdk_root"
  if command -v magic >/dev/null 2>&1; then
    ok "Magic found: $(command -v magic)"
  else
    warn "Magic not in PATH yet. It will be after you open a new terminal (PATH block added)."
  fi
  printf '%s\n' "Try:
  magic -d XR -noconsole -rcfile \"$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc\" &
  # In Magic console:  :tech    (should print 'sky130A')"
  ok "Smoke checks passed."
}

main() {
  ensure_xcode
  ensure_homebrew
  install_brew_deps
  ensure_magic
  build_open_pdks

  PDK_ROOT_FOUND="$(find_pdk_root)"
  [ -n "$PDK_ROOT_FOUND" ] || fail "Could not locate installed sky130A; check build logs."

  ok "Detected PDK_ROOT: $PDK_ROOT_FOUND"
  persist_env "$PDK_ROOT_FOUND"
  write_magic_rc
  smoke_checks "$PDK_ROOT_FOUND"
  ok "All set!"
}

main "$@"
