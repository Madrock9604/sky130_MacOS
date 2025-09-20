#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
PREFIX="${HOME}/.local/magic-aqua"   # install here (no sudo needed)
SRC_DIR="${HOME}/src"                # where to clone sources

# --- Prereqs (Homebrew) ---
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install from https://brew.sh and re-run."
  exit 1
fi

brew update
brew install tcl-tk cairo pkg-config git

HOMEBREW_PREFIX="$(brew --prefix)"               # usually /opt/homebrew on Apple Silicon
TCLTK_PREFIX="${HOMEBREW_PREFIX}/opt/tcl-tk"

# Make sure we use Homebrew's Tcl/Tk (Aqua), not MacPorts or XQuartz
export PATH="${TCLTK_PREFIX}/bin:${PATH}"
export PKG_CONFIG_PATH="${TCLTK_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I${TCLTK_PREFIX}/include ${CPPFLAGS:-}"
export LDFLAGS="-L${TCLTK_PREFIX}/lib ${LDFLAGS:-}"

# Avoid accidental use of X11
unset DISPLAY || true

# --- Get Magic source ---
mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"

if [ ! -d magic ]; then
  # Official upstream mirror
  git clone --depth=1 https://github.com/RTimothyEdwards/magic.git
fi

cd magic

# Clean previous attempts (if any)
make distclean >/dev/null 2>&1 || true
git reset --hard >/dev/null 2>&1 || true

# --- Configure for Aqua Tk (no X11) ---
./configure \
  --prefix="${PREFIX}" \
  --with-tcl="${TCLTK_PREFIX}/lib" \
  --with-tk="${TCLTK_PREFIX}/lib" \
  --with-x=no \
  --enable-cairo

# --- Build & Install ---
make -j"$(sysctl -n hw.ncpu)"
make install

# --- Post-install message ---
echo
echo "✅ Installed Magic (Aqua) to: ${PREFIX}"
echo "Add to PATH (and prefer Aqua Tcl/Tk) by adding these lines to your ~/.zshrc:"
echo "  export PATH=\"${PREFIX}/bin:${TCLTK_PREFIX}/bin:\$PATH\""
echo "  export PKG_CONFIG_PATH=\"${TCLTK_PREFIX}/lib/pkgconfig:\$PKG_CONFIG_PATH\""
echo
echo "Run now (without editing ~/.zshrc) with:"
echo "  ${PREFIX}/bin/magic"
