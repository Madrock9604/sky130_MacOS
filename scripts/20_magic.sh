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
# Bring Homebrew into PATH for this non-interactive shell
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
# PKG_CONFIG_PATH (prepend brew tcl-tk)
if [ -n "${PKG_CONFIG_PATH-}" ]; then
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig:$PKG_CONFIG_PATH"
else
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig"
fi

# Base includes for Brew Tcl/Tk + XQuartz
CPPBASE="-I$BREW_PREFIX/opt/tcl-tk/include -I/opt/X11/include"
# Key: src-relative includes so subdir builds (commands/, cmwind/, etc.) find ../database
CPPREL="-I. -I.. -I../.."

# Apply to BOTH CPPFLAGS and CFLAGS (some sub-makefiles ignore CPPFLAGS)
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

# ===== Pre-generate database/database.h to avoid parallel build race =====
if [ ! -f "database/database.h" ]; then
  echo "[INFO] Pre-generating database/database.h …"
  # 1) Try the project's Makefile rule
  if ! make database/database.h; then
    # 2) Fallback: run the generator script from repo root
    if [ ! -x "./scripts/makedbh" ]; then
      chmod +x ./scripts/makedbh || true
    fi
    if ! ./scripts/makedbh "database/database.h.in" "database/database.h"; then
      # 3) Last resort: call with csh explicitly (shebang compatibility)
      if command -v /bin/csh >/dev/null 2>&1; then
        /bin/csh ./scripts/makedbh "database/database.h.in" "database/database.h"
      else
        echo "[ERR] Could not run scripts/makedbh (csh not found)"; exit 1
      fi
    fi
  fi
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

# ===== Headless sanity check (don’t fail hard if GUI-only env) =====
if "$EDA_ROOT/opt/magic/bin/magic" -dnull -noconsole -rcfile /dev/null -e 'quit' >/dev/null 2>&1; then
  echo "[OK ] Magic headless check passed"
else
  echo "[WARN] Magic installed, but headless check failed (GUI likely fine)."
fi

echo "[OK ] Magic build finished. Try: magic &    (or later: magic-sky130 after PDK)"
