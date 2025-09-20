#!/usr/bin/env bash
# Build & install Magic using MacPorts Tk/Tcl 8.6 (X11), avoiding Homebrew Tk 9.0 crashes on XQuartz.
set -euo pipefail
IFS=$'\n\t'

# ===== Config =====
EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
SRC_DIR="${SRC_DIR:-$EDA_ROOT/src}"
BIN_DIR="$EDA_ROOT/bin"
MAGIC_REF="${MAGIC_REF:-master}"     # or pin a known-good tag/commit
PORT_PREFIX="/opt/local"             # MacPorts prefix
X11_PREFIX="/opt/X11"

# ===== Sanity: MacPorts present =====
if ! command -v port >/dev/null 2>&1; then
  echo "[ERR] MacPorts isn't installed. Run your prereqs script (00_prereqs_mac.sh) first." >&2
  exit 1
fi

# ===== Install Tk/Tcl 8.6 (X11) via MacPorts =====
# These provide Tk/Tcl headers+libs under /opt/local, plus X11 bits.
sudo port -N -q install tcl tk xorg-libX11 xorg-libXext xorg-libXi xorg-libXmu xorg-libXt cairo freetype fontconfig || {
  echo "[ERR] MacPorts package installation failed"; exit 1;
}

# ===== Prepare source dirs =====
mkdir -p "$SRC_DIR" "$BIN_DIR"
cd "$SRC_DIR"

# ===== Fetch Magic (or reuse) =====
if [ ! -d magic ]; then
  echo "[INFO] Cloning magic ($MAGIC_REF)…"
  git clone --depth=1 --branch "$MAGIC_REF" https://github.com/RTimothyEdwards/magic.git
fi
MAGIC_DIR="$SRC_DIR/magic"
cd "$MAGIC_DIR"

# ===== Toolchain: prefer MacPorts toolchain for Tk/Tcl/X11 =====
export PATH="$PORT_PREFIX/bin:$PATH"

# ===== Build flags (nounset-safe) =====
# Use MacPorts headers/libs first
CPPBASE="-I$PORT_PREFIX/include -I$X11_PREFIX/include"
CPPREL="-I. -I.. -I../.."
export CPPFLAGS="$CPPBASE $CPPREL ${CPPFLAGS-}"
export CFLAGS="$CPPBASE $CPPREL ${CFLAGS-}"
export LDFLAGS="-L$PORT_PREFIX/lib -L$X11_PREFIX/lib ${LDFLAGS-}"

# Prefer MacPorts’ pkg-config files
if [ -n "${PKG_CONFIG_PATH-}" ]; then
  export PKG_CONFIG_PATH="$PORT_PREFIX/lib/pkgconfig:$X11_PREFIX/lib/pkgconfig:$PKG_CONFIG_PATH"
else
  export PKG_CONFIG_PATH="$PORT_PREFIX/lib/pkgconfig:$X11_PREFIX/lib/pkgconfig"
fi

# ===== Clean any previous build =====
git reset --hard
git clean -xfd

# ===== Configure (single line: avoids backslash issues) =====
# Point --with-tcl/--with-tk at MacPorts lib dir (contains tclConfig.sh / tkConfig.sh for 8.6)
echo "[INFO] Configuring magic against MacPorts Tk/Tcl 8.6…"
./configure --prefix="$EDA_ROOT/opt/magic" --with-tcl="$PORT_PREFIX/lib" --with-tk="$PORT_PREFIX/lib" --x-includes="$X11_PREFIX/include" --x-libraries="$X11_PREFIX/lib"

# ===== Pre-generate auto header to avoid parallel build race =====
if [ ! -f "database/database.h" ]; then
  echo "[INFO] Pre-generating database/database.h …"
  if ! make database/database.h; then
    [ -x ./scripts/makedbh ] || chmod +x ./scripts/makedbh || true
    if ! ./scripts/makedbh "database/database.h.in" "database/database.h"; then
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
echo "[INFO] Building magic (Tk 8.6)…"
make -j"$(/usr/sbin/sysctl -n hw.ncpu)"

echo "[INFO] Installing to $EDA_ROOT/opt/magic …"
make install

# ===== Symlink into isolated bin =====
mkdir -p "$BIN_DIR"
ln -sf "$EDA_ROOT/opt/magic/bin/magic" "$BIN_DIR/magic"

# ===== Headless smoke test =====
if "$EDA_ROOT/opt/magic/bin/magic" -dnull -noconsole -rcfile /dev/null <<<'quit' >/dev/null 2>&1; then
  echo "[OK ] Magic headless check passed (Tk 8.6 build)"
else
  echo "[WARN] Magic installed, but headless check failed."
fi

cat <<'EONOTE'
[NOTE] Next:
  1) Restart XQuartz once if this is your first time using it:
        killall XQuartz 2>/dev/null || true
        open -a XQuartz
  2) Launch Magic:
        magic -d XR &
     If XR is sluggish, try: magic -d X11 &   or   magic -d cairo &
EONOTE
