#!/usr/bin/env bash
# build-magic-macos.sh
#
# One-file builder for Magic VLSI on macOS (Apple Silicon & Intel).
# - Uses Tcl/Tk **8.6** (required for Magic's build scripts).
# - Disables X11 and builds against Aqua Tk (no DISPLAY, no X11 segfaults).
# - Installs into:  $HOME/eda
#
# Optional:
#   --prefix=/custom/prefix     Change install prefix (default: $HOME/eda)
#   --tcltk-prefix=/path        Force a Tcl/Tk 8.6 prefix (bin/, lib/ inside)
#   --bootstrap-tcl86           Build a private Tcl/Tk 8.6 into $HOME/opt/tcl86
#   --no-clean                  Skip make distclean / git clean
#
# Example:
#   chmod +x scripts/build-magic-macos.sh
#   scripts/build-magic-macos.sh
#
set -euo pipefail

## ---------- tiny logger ----------
log()   { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()   { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; exit 1; }

## ---------- defaults & args ----------
PREFIX="${HOME}/eda"
TCLTK_PREFIX=""
DO_CLEAN=1
BOOTSTRAP=0

for arg in "$@"; do
  case "$arg" in
    --prefix=*)          PREFIX="${arg#*=}";;
    --tcltk-prefix=*)    TCLTK_PREFIX="${arg#*=}";;
    --bootstrap-tcl86)   BOOTSTRAP=1;;
    --no-clean)          DO_CLEAN=0;;
    *) err "Unknown option: $arg";;
  esac
done

## ---------- sanity checks ----------
[[ "$(uname -s)" == "Darwin" ]] || err "This script is for macOS."
command -v gcc >/dev/null || command -v clang >/dev/null || err "Need gcc/clang in PATH."

# Ensure we are at the root of the magic source tree (has ./configure and scripts/makedbh)
[[ -f "./configure" && -f "./scripts/makedbh" && -f "./database/database.h.in" ]] \
  || err "Run this from the Magic source root (must contain ./configure, ./scripts/makedbh, ./database/database.h.in)."

## ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

find_tcl86() {
  # If user forced a prefix, prefer that
  if [[ -n "$TCLTK_PREFIX" ]]; then
    if [[ -x "$TCLTK_PREFIX/bin/tclsh8.6" ]] && [[ -x "$TCLTK_PREFIX/bin/wish8.6" ]]; then
      echo "$TCLTK_PREFIX"
      return 0
    else
      err "--tcltk-prefix does not contain tclsh8.6 & wish8.6: $TCLTK_PREFIX"
    fi
  fi

  # MacPorts (recommended): /opt/local
  if [[ -x /opt/local/bin/tclsh8.6 && -x /opt/local/bin/wish8.6 ]]; then
    echo "/opt/local"
    return 0
  fi

  # Homebrew versioned formula (if available)
  if have brew; then
    if brew --prefix tcl-tk@8.6 >/dev/null 2>&1; then
      local p
      p="$(brew --prefix tcl-tk@8.6)"
      if [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]]; then
        echo "$p"
        return 0
      fi
    fi
    # Some brews drop version suffix but still ship 8.6
    if brew --prefix tcl-tk >/dev/null 2>&1; then
      local p
      p="$(brew --prefix tcl-tk)"
      if [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]]; then
        echo "$p"
        return 0
      fi
    fi
  fi

  # Private build (common path this script can create)
  if [[ -x "${HOME}/opt/tcl86/bin/tclsh8.6" && -x "${HOME}/opt/tcl86/bin/wish8.6" ]]; then
    echo "${HOME}/opt/tcl86"
    return 0
  fi

  return 1
}

bootstrap_tcl86() {
  log "Bootstrapping private Tcl/Tk 8.6 into \$HOME/opt/tcl86 ..."
  local work=/tmp/tcl86-build-$$
  mkdir -p "$work" "$HOME/opt/tcl86"
  pushd "$work" >/dev/null

  # Versions pinned here; adjust if you like.
  local TCL_VER=8.6.14
  local TK_VER=8.6.14

  curl -L -o "tcl${TCL_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tcl${TCL_VER}-src.tar.gz"
  tar xf "tcl${TCL_VER}-src.tar.gz"
  pushd "tcl${TCL_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86"
    make -j"$(sysctl -n hw.ncpu)"
    make install
  popd >/dev/null

  pushd "tcl${TCL_VER}/pkgs/itcl4.2.3/unix" >/dev/null || true
    if [[ -f ./configure ]]; then
      ./configure --prefix="${HOME}/opt/tcl86" --with-tcl="${HOME}/opt/tcl86/lib"
      make -j"$(sysctl -n hw.ncpu)" && make install || true
    fi
  popd >/dev/null || true

  curl -L -o "tk${TK_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tk${TK_VER}-src.tar.gz"
  tar xf "tk${TK_VER}-src.tar.gz"
  pushd "tk${TK_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86" --with-tcl="${HOME}/opt/tcl86/lib"
    make -j"$(sysctl -n hw.ncpu)"
    make install
  popd >/dev/null

  popd >/dev/null
  log "Tcl/Tk 8.6 installed at: ${HOME}/opt/tcl86"
}

## ---------- choose Tcl/Tk 8.6 ----------
if ! TCLTK_PREFIX="$(find_tcl86)"; then
  if [[ "$BOOTSTRAP" -eq 1 ]]; then
    bootstrap_tcl86
    TCLTK_PREFIX="${HOME}/opt/tcl86"
  else
    cat <<'EOF' >&2
Tcl/Tk 8.6 not found.

Options:
  1) Install via MacPorts:
       sudo port install tcl tk +quartz
     (then re-run this script)

  2) Homebrew (if formula exists):
       brew install tcl-tk@8.6
     (then re-run this script with: --tcltk-prefix="$(brew --prefix tcl-tk@8.6)")

  3) Let this script build it:
       re-run with: --bootstrap-tcl86
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

## ---------- environment hygiene ----------
# Force Aqua Tk; ensure no X11
unset DISPLAY
export PATH="${TCLTK_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:${PATH:-}"

## ---------- clean (optional but recommended) ----------
if [[ "$DO_CLEAN" -eq 1 ]]; then
  log "Cleaning tree…"
  make distclean || true
  if have git; then git clean -fdx || true; fi
fi

## ---------- pre-generate header with Tcl 8.6 ----------
log "Generating database/database.h with Tcl 8.6…"
"$TCLSH" ./scripts/makedbh ./database/database.h.in ./database/database.h
[[ -f ./database/database.h ]] || err "Failed to create database/database.h"

## ---------- configure ----------
log "Configuring Magic (no X11, Tcl/Tk 8.6)…"
./configure \
  --prefix="${PREFIX}" \
  --with-x=no \
  --with-tcl="${TCLTK_LIB}" \
  --with-tk="${TCLTK_LIB}" \
  --with-tclsh="${TCLSH}" \
  --with-wish="${WISH}"

## ---------- build & install ----------
log "Building…"
make -j"$(sysctl -n hw.ncpu)"

log "Installing to ${PREFIX}…"
make install

## ---------- sanity test ----------
log "Smoke test (headless)…"
"${PREFIX}/bin/magic" -dnull -noconsole -nowindow -rcfile /dev/null -T minimum <<<'quit' >/dev/null || {
  warn "Headless test failed—Magic still installed. Try running ${PREFIX}/bin/magic manually for messages."
}

cat <<EOF

✅ Done.

Installed binaries:
  ${PREFIX}/bin/magic
  ${PREFIX}/bin/ext2spice (and others)

Notes:
  • This build uses Aqua Tk (no X11). Don't set DISPLAY.
  • If you also have MacPorts/XQuartz/Homebrew X11 libs around, that's fine—we forced --with-x=no.

Tips:
  export PATH="${PREFIX}/bin:\$PATH"

EOF
