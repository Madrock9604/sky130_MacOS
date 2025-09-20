#!/usr/bin/env bash
# Install Magic from official release tarball on macOS (Apple Silicon & Intel)
# No external helper repos; just the upstream tarball + system packages.
# Usage (recommended):
#   curl -fsSL https://raw.githubusercontent.com/Madrock9604/sky130_MacOS/refs/heads/main/scripts/20_magic.sh \
#   | env PREFIX="$HOME/eda" MAGIC_VER="8.3.552" bash -s --
#
# Optional env vars:
#   PREFIX        Install prefix (default: $HOME/eda)
#   MAGIC_VER     Magic version tag (default: 8.3.552)
#   USE_HOMEBREW  Set=1 to force Homebrew
#   USE_MACPORTS  Set=1 to force MacPorts
#   HEADLESS      Set=1 to build without X11 GUI (Tk still okay)
#
set -Eeuo pipefail

# -------- Config --------
PREFIX="${PREFIX:-"$HOME/eda"}"
MAGIC_VER="${MAGIC_VER:-8.3.552}"
SRC_URL="https://github.com/RTimothyEdwards/magic/archive/refs/tags/${MAGIC_VER}.tar.gz"

# temp area
BUILD_ROOT="$(mktemp -d -t magic-remote-build-XXXXXX)"
TARBALL="${BUILD_ROOT}/magic-${MAGIC_VER}.tar.gz"
SRC_DIR=""

cleanup() {
  # Keep the install logs but remove big temp dirs
  [[ -d "$BUILD_ROOT" ]] && rm -rf "$BUILD_ROOT" || true
}
trap cleanup EXIT

info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
err()   { printf '[ERR ] %s\n'  "$*" >&2; exit 1; }

# -------- Detect package manager & important paths --------
HAVE_BREW=0
HAVE_PORT=0
if command -v brew >/dev/null 2>&1; then HAVE_BREW=1; fi
if command -v port >/dev/null 2>&1; then HAVE_PORT=1; fi

if [[ "${USE_HOMEBREW:-0}" == "1" ]]; then
  [[ $HAVE_BREW -eq 1 ]] || err "Homebrew requested but not found. Install it or unset USE_HOMEBREW."
  HAVE_PORT=0
elif [[ "${USE_MACPORTS:-0}" == "1" ]]; then
  [[ $HAVE_PORT -eq 1 ]] || err "MacPorts requested but not found. Install it or unset USE_MACPORTS."
  HAVE_BREW=0
fi

# Tcl/Tk + X11 prefixes
TCLTK_PREFIX=""
X11_PREFIX=""
TCLSH_BIN=""

if [[ $HAVE_PORT -eq 1 ]]; then
  # MacPorts paths
  TCLTK_PREFIX="/opt/local"
  X11_PREFIX="/opt/X11"   # XQuartz (recommended)
  TCLSH_BIN="${TCLTK_PREFIX}/bin/tclsh8.6"
elif [[ $HAVE_BREW -eq 1 ]]; then
  # Homebrew paths (Apple Silicon default prefix)
  BREW_PREFIX="$(brew --prefix)"
  # Prefer brew tcl-tk if installed, else try system
  if brew list --versions tcl-tk >/dev/null 2>&1; then
    TCLTK_PREFIX="$(brew --prefix tcl-tk)"
    # brew installs tclsh as tclsh (8.6 or 9.0 depending on formula)
    if [[ -x "${TCLTK_PREFIX}/bin/tclsh8.6" ]]; then
      TCLSH_BIN="${TCLTK_PREFIX}/bin/tclsh8.6"
    elif [[ -x "${TCLTK_PREFIX}/bin/tclsh9.0" ]]; then
      TCLSH_BIN="${TCLTK_PREFIX}/bin/tclsh9.0"
    elif command -v tclsh >/dev/null 2>&1; then
      TCLSH_BIN="$(command -v tclsh)"
    fi
  else
    # fallback to whatever is available
    TCLTK_PREFIX="${BREW_PREFIX}"
    if command -v tclsh8.6 >/dev/null 2>&1; then
      TCLSH_BIN="$(command -v tclsh8.6)"
    elif command -v tclsh >/dev/null 2>&1; then
      TCLSH_BIN="$(command -v tclsh)"
    fi
  fi
  X11_PREFIX="/opt/X11"
else
  # No package manager—try typical locations
  for p in /opt/local /opt/homebrew /usr/local; do
    [[ -d "$p" ]] && TCLTK_PREFIX="$p"
  done
  TCLSH_BIN="${TCLSH_BIN:-$(command -v tclsh8.6 || true)}"
  [[ -n "${TCLSH_BIN:-}" ]] || TCLSH_BIN="$(command -v tclsh || true)"
  X11_PREFIX="/opt/X11"
fi

[[ -d "$PREFIX" ]] || mkdir -p "$PREFIX"

info "Using install PREFIX: ${PREFIX}"
info "Tcl/Tk prefix guess: ${TCLTK_PREFIX:-"(unknown)"}"
info "Detected TCLSH: ${TCLSH_BIN:-"(not found)"}"

# -------- Check deps and give hints --------
if [[ -z "${TCLSH_BIN}" ]]; then
  warn "tclsh not found. Magic can still build if headers/libs are present, but it's recommended."
  if [[ $HAVE_BREW -eq 1 ]]; then
    warn "Try: brew install tcl-tk"
  elif [[ $HAVE_PORT -eq 1 ]]; then
    warn "Try: sudo port install tcl tk"
  fi
fi

HAVE_X11=1
if [[ "${HEADLESS:-0}" != "1" ]]; then
  if [[ ! -d "$X11_PREFIX" ]]; then
    HAVE_X11=0
    warn "XQuartz not found at ${X11_PREFIX}. GUI build will fail."
    warn "Install XQuartz from https://www.xquartz.org/ or set HEADLESS=1 for a batch-only build."
  fi
fi

# -------- Download and unpack --------
info "Downloading source archive: ${SRC_URL}"
curl -fL "$SRC_URL" -o "$TARBALL"

info "Unpacking…"
tar -xzf "$TARBALL" -C "$BUILD_ROOT"
# Find the extracted directory named magic-<ver>*
SRC_DIR="$(find "$BUILD_ROOT" -maxdepth 1 -type d -name "magic-*${MAGIC_VER}*" | head -n 1)"
[[ -d "$SRC_DIR" ]] || err "Failed to find unpacked source directory."

info "Source directory: ${SRC_DIR}"
cd "$SRC_DIR"

# -------- Configure flags --------
CFG_FLAGS=(
  "--prefix=${PREFIX}"
)

# Tcl/Tk
if [[ -n "${TCLTK_PREFIX:-}" && -d "${TCLTK_PREFIX}" ]]; then
  CFG_FLAGS+=("--with-tcl=${TCLTK_PREFIX}" "--with-tk=${TCLTK_PREFIX}")
fi

# X11 vs headless
if [[ "${HEADLESS:-0}" == "1" ]]; then
  info "HEADLESS=1: Disabling X11; Magic will run with -dnull (no GUI)."
  # No special flag needed; just avoid passing X11 includes/libs.
else
  if [[ $HAVE_X11 -eq 1 ]]; then
    CFG_FLAGS+=("--x-includes=${X11_PREFIX}/include" "--x-libraries=${X11_PREFIX}/lib")
  else
    warn "Proceeding without X11 flags. Configure will likely report X11: no; Magic GUI won't be built."
  fi
fi

# Extra safety on macOS for rpaths when using Homebrew Tcl/Tk 9.x
if [[ $HAVE_BREW -eq 1 && -n "${TCLTK_PREFIX:-}" ]]; then
  export CPPFLAGS="${CPPFLAGS:-} -I${TCLTK_PREFIX}/include"
  export LDFLAGS="${LDFLAGS:-} -L${TCLTK_PREFIX}/lib"
fi

# -------- Build --------
info "Running ./configure ${CFG_FLAGS[*]}"
./configure "${CFG_FLAGS[@]}"

info "Building (make -j$(sysctl -n hw.ncpu))…"
make -j"$(sysctl -n hw.ncpu)"

info "Installing…"
make install

# -------- Post install message --------
BIN_DIR="${PREFIX}/bin"
LIB_DIR="${PREFIX}/lib"
TCL_DIR="${PREFIX}/lib/magic/tcl"

cat <<EOF

========================================================
Magic ${MAGIC_VER} installed.

  Binaries:    ${BIN_DIR}
  Libraries:   ${LIB_DIR}
  Tcl scripts: ${TCL_DIR}

Add to your PATH (if needed):
  echo 'export PATH="${BIN_DIR}:\$PATH"' >> ~/.zshrc
  source ~/.zshrc

Run:
  magic

- If you built HEADLESS=1, start with:
    magic -dnull -noconsole <your_commands>

- If GUI was built, ensure XQuartz is running (and DISPLAY set),
  then just run:
    magic

Enjoy!
========================================================
EOF
