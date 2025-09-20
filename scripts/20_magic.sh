#!/usr/bin/env bash
# scripts/build-magic-macos.sh
#
# One-file, repo-ready builder for Magic VLSI on macOS (Apple Silicon & Intel).
# - Uses Tcl/Tk **8.6** (required by Magic's makedbh header generator).
# - Forces **no X11** (uses Aqua Tk), so DISPLAY is not needed.
# - Works locally and in CI (no prompts).
#
# Usage:
#   scripts/build-magic-macos.sh [--prefix=DIR] [--tcltk-prefix=DIR] [--bootstrap-tcl86] [--no-clean]
#
# Defaults:
#   --prefix            => $HOME/eda
#   --tcltk-prefix      => auto-detect (MacPorts, Homebrew, $HOME/opt/tcl86)
#   --bootstrap-tcl86   => build Tcl/Tk 8.6 into $HOME/opt/tcl86 if not found
#   --no-clean          => skip distclean/git clean
#
# Exit codes:
#   0 on success, non-zero on error.

set -e -o pipefail

log()  { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERR ] %s\n" "$*" >&2; exit 1; }

# -------- defaults & args --------
PREFIX="${HOME}/eda"
TCLTK_PREFIX=""
DO_CLEAN=1
BOOTSTRAP=0

for arg in "$@"; do
  case "$arg" in
    --prefix=*)        PREFIX="${arg#*=}";;
    --tcltk-prefix=*)  TCLTK_PREFIX="${arg#*=}";;
    --bootstrap-tcl86) BOOTSTRAP=1;;
    --no-clean)        DO_CLEAN=0;;
    *) err "Unknown option: $arg";;
  esac
done

# -------- sanity checks --------
[[ "$(uname -s)" == "Darwin" ]] || err "This script targets macOS."
command -v make >/dev/null || err "Need 'make' in PATH."
command -v gcc >/dev/null || command -v clang >/dev/null || err "Need gcc/clang in PATH."
[[ -f "./configure" && -f "./scripts/makedbh" && -f "./database/database.h.in" ]] \
  || err "Run from Magic source root (needs ./configure, ./scripts/makedbh, ./database/database.h.in)."

# -------- helpers --------
have() { command -v "$1" >/dev/null 2>&1; }
njobs() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

find_tcl86() {
  # 1) explicit
  if [[ -n "$TCLTK_PREFIX" ]]; then
    [[ -x "$TCLTK_PREFIX/bin/tclsh8.6" && -x "$TCLTK_PREFIX/bin/wish8.6" ]] \
      && { printf "%s\n" "$TCLTK_PREFIX"; return 0; } \
      || err "--tcltk-prefix missing tclsh8.6 or wish8.6: $TCLTK_PREFIX"
  fi
  # 2) MacPorts (/opt/local)
  if [[ -x /opt/local/bin/tclsh8.6 && -x /opt/local/bin/wish8.6 ]]; then
    printf "%s\n" "/opt/local"; return 0
  fi
  # 3) Homebrew (formula may be tcl-tk@8.6 or tcl-tk)
  if have brew; then
    if brew --prefix tcl-tk@8.6 >/dev/null 2>&1; then
      local p; p="$(brew --prefix tcl-tk@8.6)"
      [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { printf "%s\n" "$p"; return 0; }
    fi
    if brew --prefix tcl-tk >/dev/null 2>&1; then
      local p; p="$(brew --prefix tcl-tk)"
      [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { printf "%s\n" "$p"; return 0; }
    fi
  fi
  # 4) user-local
  if [[ -x "${HOME}/opt/tcl86/bin/tclsh8.6" && -x "${HOME}/opt/tcl86/bin/wish8.6" ]]; then
    printf "%s\n" "${HOME}/opt/tcl86"; return 0
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

  command -v curl >/dev/null || err "Need 'curl' to bootstrap Tcl/Tk."

  curl -L -o "tcl${TCL_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tcl${TCL_VER}-src.tar.gz"
  tar xf "tcl${TCL_VER}-src.tar.gz"
  pushd "tcl${TCL_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86"
    make -j"$(njobs)"; make install
  popd >/dev/null

  curl -L -o "tk${TK_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tk${TK_VER}-src.tar.gz"
  tar xf "tk${TK_VER}-src.tar.gz"
  pushd "tk${TK_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86" --with-tcl="${HOME}/opt/tcl86/lib"
    make -j"$(njobs)"; make install
  popd >/dev/null

  popd >/dev/null
  log "Tcl/Tk 8.6 installed at: ${HOME}/opt/tcl86"
}

# -------- locate or make Tcl/Tk 8.6 --------
if ! TCLTK_PREFIX="$(find_tcl86)"; then
  if [[ "$BOOTSTRAP" -eq 1 ]]; then
    bootstrap_tcl86
    TCLTK_PREFIX="${HOME}/opt/tcl86"
  else
    cat <<'EOF' >&2
[ERR ] Tcl/Tk 8.6 not found.

Install one of these, or re-run with --bootstrap-tcl86:

  MacPorts:
    sudo port install tcl tk +quartz

  Homebrew:
    brew install tcl-tk@8.6
    # (or) brew install tcl-tk   # if 8.6 is the provided version

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

# -------- clean (optional) --------
if [[ "$DO_CLEAN" -eq 1 ]]; then
  log "Cleaning tree (distclean + git clean -fdx if available)..."
  make distclean || true
  if have git; then git clean -fdx || true; fi
fi

# -------- avoid X11 --------
unset DISPLAY
export PATH="${TCLTK_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:${PATH:-}"

# -------- pre-generate the DB header (fixes database.h missing) --------
log "Generating database/database.h with Tcl 8.6..."
"$TCLSH" ./scripts/makedbh ./database/database.h.in ./database/database.h
[[ -f ./database/database.h ]] || err "Failed to create database/database.h"

# -------- configure (force no X11; wire Tcl/Tk 8.6 paths) --------
log "Configuring Magic (no X11, Tcl/Tk 8.6)..."
./configure \
  --prefix="${PREFIX}" \
  --with-x=no \
  --with-tcl="${TCLTK_LIB}" \
  --with-tk="${TCLTK_LIB}" \
  --with-tclsh="${TCLSH}" \
  --with-wish="${WISH}"

# -------- build & install --------
log "Building..."
make -j"$(njobs)"

log "Installing to ${PREFIX}..."
make install

# -------- smoke test (headless) --------
log "Smoke test (headless)..."
if ! "${PREFIX}/bin/magic" -dnull -noconsole -nowindow -rcfile /dev/null -T minimum <<<'quit' >/dev/null 2>&1; then
  warn "Headless test failed; Magic is installed but GUI/rcfile/tech may need attention."
fi

cat <<'EOF'

Done.

Installed binaries include:
  ${PREFIX}/bin/magic
  ${PREFIX}/bin/ext2spice

Notes:
  - Build uses Aqua Tk (no X11). Ensure DISPLAY is unset when running the GUI build.
  - If you *want* X11 later, reconfigure without '--with-x=no' and ensure libX11 headers/libs are present.

Tip:
  export PATH="${PREFIX}/bin:$PATH"

EOF

