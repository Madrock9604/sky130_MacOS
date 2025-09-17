#!/bin/sh
# macOS SKY130 — One‑Shot Installer (POSIX sh, single run)
# --------------------------------------------------------
# After this completes, you can launch Magic with SKY130A tech on a clean macOS.
# What it does:
#   1) Ensures Xcode CLT
#   2) Installs Homebrew (if missing) and deps: tcl-tk, ngspice, gnu-sed, cmake, git, etc., plus XQuartz (+ KLayout)
#   3) Ensures a working 'magic' binary:
#        • If MacPorts is available, offers to install Magic via MacPorts (with sudo / GUI prompt fallback)
#        • Otherwise builds Magic from source into $MAGIC_PREFIX (no sudo)
#   4) Builds & installs open_pdks (sky130A) under $PDK_PREFIX/share/pdk
#   5) Persists env vars (PDK_ROOT, PATH, etc.) and writes a safe ~/.magicrc
#   6) Runs a headless Magic smoke test loading sky130A
#
# Usage:
#   sh install-mac.sh
#   sh install-mac.sh -y            # auto-yes (no prompts)
#   sh install-mac.sh --dry-run     # preview actions

set -eu

YES=false
DRY=false

# ----- arg parsing -----
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '1,200p' "$0"; exit 0 ;;
    *) printf '[!] Unknown arg: %s
' "$1" ;;
  esac
  shift
done

# ----- helpers -----
info() { printf '[1;34m[i][0m %s
' "$*"; }
ok()   { printf '[1;32m[✓][0m %s
' "$*"; }
warn() { printf '[1;33m[!][0m %s
' "$*"; }
fail() { printf '[1;31m[x][0m %s
' "$*"; exit 1; }

confirm() {
  prompt="$1"
  if [ "$YES" = true ]; then return 0; fi
  printf '%s [y/N]: ' "$prompt"
  read ans || ans=""
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

run() {
  if [ "$DRY" = true ]; then
    printf 'DRY-RUN: %s
' "$*"
  else
    # shellcheck disable=SC2086
    sh -c "$*"
  fi
}

# GUI/TTY aware elevation for MacPorts
HAS_TTY=0; [ -t 1 ] && HAS_TTY=1
run_admin() {
  _cmd="$1"
  if [ "$DRY" = true ]; then
    [ "$HAS_TTY" -eq 1 ] && printf 'DRY-RUN sudo %s
' "$_cmd" || printf 'DRY-RUN (GUI sudo) %s
' "$_cmd"
    return 0
  fi
  if [ "$HAS_TTY" -eq 1 ]; then
    sudo -n true 2>/dev/null || sudo -v || { printf '[x] Admin privileges required.
'; exit 1; }
    sh -c "sudo $_cmd"
  else
    _esc=$(printf '%s' "$_cmd" | sed 's/\/\\/g; s/"/\"/g')
    /usr/bin/osascript -e "do shell script \"$_esc\" with administrator privileges"
  fi
}

# ----- defaults / paths -----
PDK_PREFIX="${PDK_PREFIX:-$HOME/eda/pdks}"
PDK_ROOT_DEFAULT="$PDK_PREFIX/share/pdk"
MAGIC_PREFIX="${MAGIC_PREFIX:-$HOME/eda/tools}"
SRC_ROOT="${SRC_ROOT:-$HOME/eda/src}"
mkdir -p "$PDK_PREFIX" "$MAGIC_PREFIX" "$SRC_ROOT"

BREW_BIN=$(command -v brew 2>/dev/null || printf '')
PORT_BIN=$(command -v port 2>/dev/null || printf '')
CORES=$(sysctl -n hw.ncpu 2>/dev/null || printf '2')

# ----- 0) Xcode CLT -----
ensure_xcode() {
  if ! xcode-select -p >/dev/null 2>&1; then
    info "Installing Xcode Command Line Tools…"
    run "xcode-select --install || true"
    warn "If a dialog appeared, complete it, then re-run this script."
  fi
  ok "Xcode Command Line Tools present."
}

# ----- 1) Homebrew (for deps) -----
ensure_homebrew() {
  # If brew already exists, just wire it up and return
  if command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
    # Make sure shellenv is active in this session
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew present at $(brew --prefix 2>/dev/null || printf 'unknown')."
    return 0
  fi

  info "Installing Homebrew…"

  # Use NONINTERACTIVE if installer was called with -y
  if [ "${YES:-false}" = true ]; then
    # Non-interactive, but still attach to /dev/tty so password/CLT prompts work if needed
    run 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty'
  else
    # Interactive path (attach stdin to the real terminal, not the pipeline)
    run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty'
  fi

  # Detect brew location (Apple Silicon vs Intel) and export for this session
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  else
    # Fallback: search common roots in case the installer finished but PATH isn't set yet
    BREW_BIN="$(/usr/bin/find /opt /usr/local "$HOME" -type f -name brew -maxdepth 4 2>/dev/null | /usr/bin/head -n1 || true)"
    if [ -n "$BREW_BIN" ]; then
      eval "$("$BREW_BIN" shellenv)"
    fi
  fi

  BREW_BIN="$(command -v brew 2>/dev/null || true)"
  [ -n "$BREW_BIN" ] || fail "Homebrew installation appears to have failed."

  # Persist Homebrew shellenv to ~/.zprofile so new terminals have brew on PATH
  ZFILE="$HOME/.zprofile"
  if ! grep -q 'Homebrew (added by sky130 installer)' "$ZFILE" 2>/dev/null; then
    {
      echo ""
      echo "# Homebrew (added by sky130 installer)"
      if [ -x /opt/homebrew/bin/brew ]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
      else
        echo 'eval "$(/usr/local/bin/brew shellenv)"'
      fi
    } >> "$ZFILE"
  fi

  ok "Homebrew installed at $(brew --prefix)"
}


# ----- 2) Homebrew dependencies -----
install_brew_deps() {
  info "Installing build/runtime dependencies with Homebrew…"
  run "brew update"
  run "brew install git automake autoconf libtool pkg-config gawk wget xz tcl-tk ngspice cmake gnu-sed"
  run "brew install --cask xquartz || true"
  run "brew install klayout || brew install --cask klayout || true"
  ok "Dependencies installed."
}

# ----- 3) Ensure MAGIC -----
install_magic_via_macports() {
  [ -n "$PORT_BIN" ] || return 1
  info "Installing Magic via MacPorts…"
  run_admin "${PORT_BIN:-/opt/local/bin/port} -N selfupdate || true"
  run_admin "${PORT_BIN:-/opt/local/bin/port} -N install magic"
  PATH="/opt/local/bin:$PATH"; export PATH
  command -v magic >/dev/null 2>&1 || return 1
  ok "Magic installed via MacPorts."
  return 0
}

build_magic_from_source() {
  info "Building Magic from source into $MAGIC_PREFIX …"
  TCLTK_PREFIX=$(brew --prefix tcl-tk 2>/dev/null || printf '')
  if [ -n "$TCLTK_PREFIX" ]; then
    if [ "$DRY" = false ]; then
      export CFLAGS="-I$TCLTK_PREFIX/include ${CFLAGS-}"
      export LDFLAGS="-L$TCLTK_PREFIX/lib ${LDFLAGS-}"
      export PKG_CONFIG_PATH="$TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    fi
  fi
  mkdir -p "$SRC_ROOT" && cd "$SRC_ROOT"
  if [ ! -d magic ]; then
    run "git clone https://github.com/RTimothyEdwards/magic.git"
  fi
  cd magic
  run "git fetch --all -q && git pull -q"
  run "./configure --prefix='$MAGIC_PREFIX' --with-x --with-opengl=no --disable-cairo ${TCLTK_PREFIX:+--with-tcl='$TCLTK_PREFIX/lib' --with-tk='$TCLTK_PREFIX/lib' --with-tclinclude='$TCLTK_PREFIX/include' --with-tkinclude='$TCLTK_PREFIX/include'}"
  run "make -j$CORES"
  run "make install"
  PATH="$MAGIC_PREFIX/bin:$PATH"; export PATH
  command -v magic >/dev/null 2>&1 || fail "Magic built but not found in PATH."
  ok "Magic built and installed to $MAGIC_PREFIX."
}

ensure_magic() {
  if command -v magic >/dev/null 2>&1; then
    ok "Magic already present: $(command -v magic)"
    return 0
  fi
  if [ -n "$PORT_BIN" ]; then
    if confirm "MacPorts detected. Install Magic via MacPorts (admin required)?"; then
      install_magic_via_macports && return 0
      warn "MacPorts installation failed; will try building from source."
    fi
  fi
  if confirm "Build Magic from source under $MAGIC_PREFIX (no sudo)?"; then
    build_magic_from_source
  else
    fail "Magic is required by open_pdks. Aborting."
  fi
}

# ----- 4) Build & install open_pdks (sky130A) -----
build_open_pdks() {
  info "Building and installing open_pdks (sky130A)…"
  mkdir -p "$SRC_ROOT" "$PDK_PREFIX"
  cd "$SRC_ROOT"
  if [ ! -d open_pdks ]; then
    run "git clone https://github.com/RTimothyEdwards/open_pdks.git"
  fi
  cd open_pdks
  run "git fetch --all -q && git pull -q"
  run "make clean || git clean -xfd || true"
  TCLTK_PREFIX=$(brew --prefix tcl-tk 2>/dev/null || printf '')
  if [ -n "$TCLTK_PREFIX" ] && [ "$DRY" = false ]; then
    export LDFLAGS="-L$TCLTK_PREFIX/lib ${LDFLAGS-}"
    export CPPFLAGS="-I$TCLTK_PREFIX/include ${CPPFLAGS-}"
    export PKG_CONFIG_PATH="$TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi
  # Ensure magic is in PATH for configure to find it
  PATH="$MAGIC_PREFIX/bin:$PATH"; export PATH
  run "./configure --prefix='$PDK_PREFIX' --enable-sky130-pdk --with-sky130-variants=A"
  run "make -j$CORES"
  run "make -j$CORES install"
  ok "open_pdks installed under $PDK_PREFIX"
}

# ----- 5) Locate PDK_ROOT -----
find_pdk_root() {
  cand="$PDK_ROOT_DEFAULT"
  if [ -f "$cand/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf '%s' "$cand"; return 0
  fi
  found=$(find "$PDK_PREFIX" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || printf '')
  if [ -n "$found" ]; then
    d1=$(dirname "$found"); d2=$(dirname "$d1"); d3=$(dirname "$d2"); sky=$(dirname "$d3")
    printf '%s' "$(dirname "$sky")"; return 0
  fi
  brew_share=$(brew --prefix 2>/dev/null)/share/pdk
  if [ -d "$brew_share" ]; then
    found=$(find "$brew_share" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || printf '')
    if [ -n "$found" ]; then
      d1=$(dirname "$found"); d2=$(dirname "$d1"); d3=$(dirname "$d2"); sky=$(dirname "$d3")
      printf '%s' "$(dirname "$sky")"; return 0
    fi
  fi
  printf '%s' ""
}

# ----- 6) Persist env + Magic rc -----
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
  run "rm -f '$HOME/.config/sky130/rc_wrapper.tcl' 2>/dev/null || true"
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

# ----- 7) Smoke test (headless) -----
smoke_test() {
  pdk_root="$1"
  info "Running headless Magic smoke test (load sky130A)…"
  if command -v magic >/dev/null 2>&1; then
    # Use -d null to avoid GUI; exit immediately after load
    if run "magic -T sky130A -noconsole -d null -rcfile '$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc' -eval exit"; then
      ok "Magic successfully loaded sky130A."
    else
      warn "Magic test failed. You can still try: magic -T sky130A -rcfile '$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc'"
    fi
  else
    warn "Magic not in PATH in this shell yet. Open a new terminal (env persisted)."
  fi
}

main() {
  ensure_xcode
  ensure_homebrew
  install_brew_deps
  ensure_magic
  build_open_pdks
  PDK_ROOT_FOUND=$(find_pdk_root)
  [ -n "$PDK_ROOT_FOUND" ] || fail "Could not locate installed sky130A; check build logs."
  ok "Detected PDK_ROOT: $PDK_ROOT_FOUND"
  persist_env "$PDK_ROOT_FOUND"
  write_magic_rc
  smoke_test "$PDK_ROOT_FOUND"
  ok "All set!"
}

main "$@"
