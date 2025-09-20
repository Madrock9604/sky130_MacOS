#!/usr/bin/env bash
# Install Magic VLSI from the official release tarball (no external build repos)
# Usage (GUI):     curl -fsSL <raw-url> | env PREFIX="$HOME/eda" MAGIC_VER="8.3.552" bash -s --
# Usage (headless):curl -fsSL <raw-url> | env PREFIX="$HOME/eda" MAGIC_VER="8.3.552" HEADLESS=1 bash -s --

set -Eeuo pipefail

# ---------- Config ----------
PREFIX="${PREFIX:-"$HOME/eda"}"          # install prefix
MAGIC_VER="${MAGIC_VER:-8.3.552}"        # Magic release tag
SRC_URL="https://github.com/RTimothyEdwards/magic/archive/refs/tags/${MAGIC_VER}.tar.gz"

# Optional env toggles:
#   USE_HOMEBREW=1  -> prefer Homebrew paths
#   USE_MACPORTS=1  -> prefer MacPorts paths
#   HEADLESS=1      -> force no-X11 build

# ---------- Helpers ----------
info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
err(){ printf '[ERR ] %s\n' "$*" >&2; exit 1; }

BUILD_ROOT="$(mktemp -d -t magic-remote-build-XXXXXX)"
TARBALL="${BUILD_ROOT}/magic-${MAGIC_VER}.tar.gz"
cleanup(){ [[ -d "$BUILD_ROOT" ]] && rm -rf "$BUILD_ROOT" || true; }
trap cleanup EXIT

# ---------- Toolchain / paths ----------
HAVE_BREW=0; HAVE_PORT=0
command -v brew >/dev/null 2>&1 && HAVE_BREW=1
command -v port >/dev/null 2>&1 && HAVE_PORT=1
if [[ "${USE_HOMEBREW:-0}" == "1" ]]; then [[ $HAVE_BREW -eq 1 ]] || err "Homebrew requested but not found"; HAVE_PORT=0; fi
if [[ "${USE_MACPORTS:-0}" == "1" ]]; then [[ $HAVE_PORT -eq 1 ]] || err "MacPorts requested but not found"; HAVE_BREW=0; fi

TCLTK_PREFIX=""; X11_PREFIX=""; TCLSH_BIN=""

if [[ $HAVE_PORT -eq 1 ]]; then
  TCLTK_PREFIX="/opt/local"
  TCLSH_BIN="/opt/local/bin/tclsh8.6"
  X11_PREFIX="/opt/X11"
elif [[ $HAVE_BREW -eq 1 ]]; then
  BREW_PREFIX="$(brew --prefix)"
  if brew list --versions tcl-tk >/dev/null 2>&1; then
    TCLTK_PREFIX="$(brew --prefix tcl-tk)"
    # pick a tclsh
    for c in tclsh8.6 tclsh9.0 tclsh; do command -v "$c" >/dev/null 2>&1 && TCLSH_BIN="$(command -v "$c")" && break; done
  else
    TCLTK_PREFIX="$BREW_PREFIX"
    for c in tclsh8.6 tclsh; do command -v "$c" >/dev/null 2>&1 && TCLSH_BIN="$(command -v "$c")" && break; done
  fi
  X1="/opt/X11"; [[ -d "$X1" ]] && X11_PREFIX="$X1" || X11_PREFIX=""
else
  # fallback heuristics
  for p in /opt/local /opt/homebrew /usr/local; do [[ -d "$p" ]] && TCLTK_PREFIX="$p"; done
  TCLSH_BIN="$(command -v tclsh8.6 || true)"; [[ -n "${TCLSH_BIN:-}" ]] || TCLSH_BIN="$(command -v tclsh || true)"
  [[ -d /opt/X11 ]] && X11_PREFIX="/opt/X11" || X11_PREFIX=""
fi

[[ -d "$PREFIX" ]] || mkdir -p "$PREFIX"

info "Using install PREFIX: ${PREFIX}"
info "Detected TCLSH: ${TCLSH_BIN:-"(not found)"}"
info "TCL/TK prefix: ${TCLTK_PREFIX:-"(unknown)"}"
if [[ "${HEADLESS:-0}" == "1" ]]; then
  info "HEADLESS=1 -> building without X11 GUI"
elif [[ -n "$X11_PREFIX" && -d "$X11_PREFIX" ]]; then
  info "X11 detected at ${X11_PREFIX} (XQuartz). Magic will build with GUI."
else
  warn "X11 not found; will fall back to headless. Install XQuartz to enable GUI: https://www.xquartz.org/"
  export HEADLESS=1
fi

# ---------- Fetch & unpack ----------
info "Downloading source archive: ${SRC_URL}"
curl -fL "$SRC_URL" -o "$TARBALL"
info "Unpacking…"
tar -xzf "$TARBALL" -C "$BUILD_ROOT"
SRC_DIR="$(find "$BUILD_ROOT" -maxdepth 1 -type d -name "magic-*${MAGIC_VER}*" | head -n 1)"
[[ -d "$SRC_DIR" ]] || err "Failed to find unpacked source directory"
info "Source directory: ${SRC_DIR}"
cd "$SRC_DIR"

# ---------- Configure ----------
CFG_FLAGS=( "--prefix=${PREFIX}" )
[[ -n "${TCLTK_PREFIX:-}" && -d "${TCLTK_PREFIX}" ]] && CFG_FLAGS+=( "--with-tcl=${TCLTK_PREFIX}" "--with-tk=${TCLTK_PREFIX}" )

if [[ "${HEADLESS:-0}" == "1" ]]; then
  CFG_FLAGS+=( "--with-x=no" )
else
  # Help configure find X headers/libs from XQuartz
  if [[ -n "${X11_PREFIX:-}" && -d "${X11_PREFIX}" ]]; then
    CFG_FLAGS+=( "--x-includes=${X11_PREFIX}/include" "--x-libraries=${X11_PREFIX}/lib" )
  fi
fi

# On Homebrew, be explicit so headers/libs are found
if [[ $HAVE_BREW -eq 1 && -n "${TCLTK_PREFIX:-}" ]]; then
  export CPPFLAGS="${CPPFLAGS:-} -I${TCLTK_PREFIX}/include"
  export LDFLAGS="${LDFLAGS:-} -L${TCLTK_PREFIX}/lib"
fi

info "Running ./configure ${CFG_FLAGS[*]}"
./configure "${CFG_FLAGS[@]}"

# ---------- Build & Install ----------
JOBS="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
info "Building (make -j${JOBS})…"
make -j"${JOBS}"

info "Installing…"
make install

# ---------- Summary ----------
BIN_DIR="${PREFIX}/bin"
LIB_DIR="${PREFIX}/lib"
TCL_DIR="${PREFIX}/lib/magic/tcl"

cat <<EON

========================================================
Magic ${MAGIC_VER} installed.

  Binaries:    ${BIN_DIR}
  Libraries:   ${LIB_DIR}
  Tcl scripts: ${TCL_DIR}

Add to PATH:
  echo 'export PATH="${BIN_DIR}:\$PATH"' >> ~/.zshrc && source ~/.zshrc

Run:
  magic        # (if GUI built)
  # or: magic -dnull -noconsole   # headless batch

Notes:
  - Set HEADLESS=1 to force no-X11 build.
  - Set USE_HOMEBREW=1 or USE_MACPORTS=1 to prefer those trees.
========================================================
EON
