#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'


EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
SRC_DIR="${SRC_DIR:-$EDA_ROOT/src}"
BIN_DIR="$EDA_ROOT/bin"
MAGIC_REF="${MAGIC_REF:-master}" # use a tag/commit if you want determinism


if command -v brew >/dev/null 2>&1; then eval "$($(command -v brew) shellenv)"; fi
BREW_PREFIX=$(brew --prefix)


mkdir -p "$SRC_DIR" "$BIN_DIR"
cd "$SRC_DIR"


if [ ! -d magic ]; then
echo "[INFO] Cloning magic…"
git clone --depth=1 --branch "$MAGIC_REF" https://github.com/RTimothyEdwards/magic.git
fi
cd magic


# Configure with Tcl/Tk from Homebrew and XQuartz headers/libs
# (Works with: set -euo pipefail)
if [ -n "${PKG_CONFIG_PATH-}" ]; then
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig:$PKG_CONFIG_PATH"
else
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig"
fi

export CPPFLAGS="-I$BREW_PREFIX/opt/tcl-tk/include -I/opt/X11/include ${CPPFLAGS-}"
export LDFLAGS="-L$BREW_PREFIX/opt/tcl-tk/lib -L/opt/X11/lib ${LDFLAGS-}"


# Ensure a clean tree (important if you retried earlier)
git reset --hard
git clean -xfd

./configure \
  --prefix="$EDA_ROOT/opt/magic" \
  --with-tcl="$BREW_PREFIX/opt/tcl-tk/lib" \
  --with-tk="$BREW_PREFIX/opt/tcl-tk/lib" \
  --x-includes=/opt/X11/include \
  --x-libraries=/opt/X11/lib \
  --enable-cairo

# *** Key fix: guarantee src-relative includes during subdir builds ***
export CFLAGS="${CFLAGS:-} -I.. -I../.."

make -j"$(( $(/usr/sbin/sysctl -n hw.ncpu) ))"
make install



ln -sf "$EDA_ROOT/opt/magic/bin/magic" "$BIN_DIR/magic"


# Headless sanity check
"$EDA_ROOT/opt/magic/bin/magic" -dnull -noconsole -rcfile /dev/null -e 'quit' >/dev/null 2>&1 && \
echo "[OK ] magic installed: $($EDA_ROOT/opt/magic/bin/magic -v | head -n1)" || \
echo "[WARN] magic installed, but headless check failed (GUI likely fine)."
