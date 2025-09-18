#!/usr/bin/env bash
# Build & install Magic from source (Homebrew + XQuartz), isolated under ~/.eda/sky130
set -euo pipefail
IFS=$'\n\t'

# ===== Config =====
EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
SRC_DIR="${SRC_DIR:-$EDA_ROOT/src}"
BIN_DIR="$EDA_ROOT/bin"
MAGIC_REF="${MAGIC_REF:-master}"   # set to a tag/commit for reproducible builds

# ===== Prep =====
if command -v brew >/dev/null 2>&1; then
  eval "$($(command -v brew) shellenv)"
else
  echo "[ERR] Homebrew not found. Run 00_prereqs_mac.sh first." >&2
  exit 1
fi
BREW_PREFIX="$(brew --prefix)"

mkdir -p "$SRC_DIR" "$BIN_DIR"
cd "$SRC_DIR"

# ===== Clone (or reuse) repo =====
if [ ! -d magic ]; then
  echo "[INFO] Cloning magic ($MAGIC_REF)…"
  git clone --depth=1 --branch "$MAGIC_REF" https://github.com/RTimothyEdwards/magic.git
fi
MAGIC_DIR="$SRC_DIR/magic"
cd "$MAGIC_DIR"

# ===== Build flags (nounset-safe) =====
if [ -n "${PKG_CONFIG_PATH-}" ]; then
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig:$PKG_CONFIG_PATH"
else
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig"
fi

CPPBASE="-I$BREW_PREFIX/opt/tcl-tk/include -I/opt/X11/include"
CPPREL="-I. -I.. -I../.."
export CPPFLAGS="$CPPBASE $CPPREL ${CPPFLAGS-}"
export CFLAGS="$CPPBASE $CPPREL ${CFLAGS-}"
export LDFLAGS="-L$BREW_PREFIX/opt/tcl-tk/lib -L/opt/X11/lib ${LDFLAGS-}"

# ===== Clean tree (important after failed attempts) =====
git reset --hard
git clean -xfd

# ===== Configure =====
echo "[INFO] Configuring magic…"
./configure \
  --prefix="$EDA_ROOT/opt/magic" \
  --with-tcl="$BREW_PREFIX/opt/tcl-tk/lib" \
  --with-tk="$BREW_PREFIX/opt/tcl-tk/lib" \
  --x-includes=/opt/X11/include \
  --x-libraries=/opt/X11/lib \
  --enable-cairo

# ===== Pre-generate database/database.h to avoid parallel race =====
if [ ! -f "database/database.h" ]; then
  echo "[INFO] Pre-generating database/database.h …"
  # Prefer the Makefile rule (same as the project uses), fall back to the script.
  make database/database.h || ./scripts/makedbh "database/database.h.in" "database/database.h"
fi
[ -f "database/database.h" ] || { echo "[ERR] Failed to generate database/database.h"; exit 1; }

# ===== Build & install =====
echo "[INFO] Building magic…"
make -j"$(/usr/sbin/sysctl -n hw.ncpu)"

echo "[INFO] Installing magic to $EDA_ROOT/opt/magic …"
make install

# ===== Symlink into isolated bin =====
mkdir -p "$BIN_DIR"
ln -sf "$EDA_ROOT/opt/magic/bin/magic" "$BIN_DIR/magic"

# ===== Headless sanity check =====
if "$EDA_ROOT/opt/magic/bin/magic" -dnull -noconsole -rcfile /dev/null -e 'quit' >/dev/null 2>&1; then
  echo "[OK ] Magic headless check passed"
else
  echo "[WARN] Magic installed, but headless check failed (GUI likely fine)."
fi

echo "[OK ] Magic build finished. Try: magic &    (or later: magic-sky130 after PDK)"
