#!/usr/bin/env bash
# build-magic-macos.sh
# One-file builder for Magic VLSI on macOS (Apple Silicon & Intel).
# - Uses Tcl/Tk 8.6 (required by Magic's makedbh).
# - Disables X11 and uses Aqua Tk (no DISPLAY).
# - Installs into $HOME/eda by default.

set -e -o pipefail

log()  { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERR ] %s\n" "$*" >&2; exit 1; }

# Defaults
PREFIX="${HOME}/eda"
TCLTK_PREFIX=""
DO_CLEAN=1
BOOTSTRAP=0

# Args
for arg in "$@"; do
  case "$arg" in
    --prefix=*)        PREFIX="${arg#*=}";;
    --tcltk-prefix=*)  TCLTK_PREFIX="${arg#*=}";;
    --bootstrap-tcl86) BOOTSTRAP=1;;
    --no-clean)        DO_CLEAN=0;;
    *) err "Unknown option: $arg";;
  endac
done 2>/dev/null || true

have() { command -v "$1" >/dev/null 2>&1; }

[[ "$(uname -s)" == "Darwin" ]] || err "This script is for macOS."
command -v gcc >/dev/null || command -v clang >/dev/null || err "Need gcc/clang in PATH."

# Must be run from Magic source root
[[ -f "./configure" && -f "./scripts/makedbh" && -f "./database/database.h.in" ]] \
  || err "Run from Magic source root (needs ./configure, ./scripts/makedbh, ./database/database.h.in)."

find_tcl86() {
  if [[ -n "$TCLTK_PREFIX" ]]; then
    [[ -x "$TCLTK_PREFIX/bin/tclsh8.6" && -x "$TCLTK_PREFIX/bin/wish8.6" ]] \
      && { echo "$TCLTK_PREFIX"; return 0; } \
      || err "--tcltk-prefix missing tclsh8.6 or wish8.6: $TCLTK_PREFIX"
  fi
  if [[ -x /opt/local/bin/tclsh8.6 && -x /opt/local/bin/wish8.6 ]]; then
    echo "/opt/local"; return 0
  fi
  if have brew; then
    if brew --prefix tcl-tk@8.6 >/dev/null 2>&1; then
      local p; p="$(brew --prefix tcl-tk@8.6)"
      [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { echo "$p"; return 0; }
    fi
    if brew --prefix tcl-tk >/dev/null 2>&1; then
      local p; p="$(brew --prefix tcl-tk)"
      [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { echo "$p"; return 0; }
    fi
  fi
  if [[ -x "${HOME}/opt/tcl86/bin/tclsh8.6" && -x "${HOME}/opt/tcl86/bin/wish8.6" ]]; then
    echo "${HOME}/opt/tcl86"; return 0
  fi
  return 1
}

bootstrap_tcl86() {
  log "Bootstrapping Tcl/Tk 8.6 into \$HOME/opt/tcl86 ..."
  local work="/tmp/tcl86-build-$$"
  mkdir -p "$work" "$HOME/opt/tcl86"
  pushd "$work" >/dev/null

  local TCL_VER=8.6.14
  local TK_VER=8.6.14

  curl -L -o "tcl${TCL_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tcl${TCL_VER}-src.tar.gz"
  tar xf "tcl${TCL_VER}-src.tar.gz"
  pushd "tcl${TCL_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86"
    make -j"$(sysctl -n hw.ncpu)"; make install
  popd >/dev/null

  curl -L -o "tk${TK_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tk${TK_VER}-src.tar.gz"
  tar xf "tk${TK_VER}-src.tar.gz"
  pushd "tk${TK_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86" --with-tcl="${HOME}/opt/tcl86/lib"
    make -j"$(sysctl -n hw.ncpu)"; make install
  popd >/dev/null

  popd >/dev/null
  log "Tcl/Tk 8.6 ready at: ${HOME}/opt/tcl86"
}

# Locate or make Tcl/Tk 8.6
if ! TCLTK_PREFIX="$(find_tcl86)"; then
  if [[ "$BOOTSTRAP" -eq 1 ]]; then
    bootstrap_tcl86
    TCLTK_PREFIX="${HOME}/opt/tcl86"
  else
    cat <<'EOF' >&2
Tcl/Tk 8.6 not found.

Options:
  1) MacPorts:
       sudo port install tcl tk +quartz
  2) Homebrew (if available):
       brew install tcl-tk@8.6
  3) Let this script build it:
       re-run with --bootstrap-tcl86
EOF
    exit 1
  fi
fi

TCLSH="${TCLTK_PREFIX}/bin/tclsh8.6"
WISH="${TCLTK_PREFIX}/bin/wish8.6"
TCLTK_LIB="${TCLTK_PREFIX}/lib"
[[ -x "$TCLSH" ]] || err "Missing $TCLSH"
[[ -x "$WISH"  ]] || err "Missing $WISH"

log "Using Tcl/Tk 8.6 at: $TCLTK_PREFIX"
log "tclsh: $TCLSH"
log "wish : $WISH"

# Force Aqua Tk; avoid X11
unset DISPLAY
export PATH="${TCLTK_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:${PATH:-}"

# Clean
if [[ "$DO_CLEAN" -eq 1 ]]; then
  log "Cleaning tree..."
  make distclean || true
  if have git; then git clean -fdx || true; fi
fi

# Pre-generate the header (fixes database/database.h not found)
log "Generating database/database.h with Tcl 8.6..."
"$TCLSH" ./scripts/makedbh ./database/database.h.in ./database/database.h
[[ -f ./database/database.h ]] || err "Failed to create database/database.h"

# Configure (no X11)
log "Configuring Magic (no X11, Tcl/Tk 8.6)..."
./configure \
  --prefix="${PREFIX}" \
  --with-x=no \
  --with-tcl="${TCLTK_LIB}" \
  --with-tk="${TCLTK_LIB}" \
  --with-tclsh="${TCLSH}" \
  --with-wish="${WISH}"

# Build & install
log "Building..."
make -j"$(sysctl -n hw.ncpu)"

log "Installing to ${PREFIX}..."
make install

# Smoke test (headless)
log "Smoke test (headless)..."
"${PREFIX}/bin/magic" -dnull -noconsole -nowindow -rcfile /dev/null -T minimum <<<'quit' >/dev/null || {
  warn "Headless test failed; Magic installed anyway. Try running ${PREFIX}/bin/magic manually."
}

cat <<'EOF'

Done.

Installed binaries include:
  ${PREFIX}/bin/magic
  ${PREFIX}/bin/ext2spice

Notes:
  - This build uses Aqua Tk (no X11). Do not set DISPLAY.
  - If X11 libs are installed, that's fine; we forced --with-x=no.

Tip:
  export PATH="${PREFIX}/bin:$PATH"

EOF
