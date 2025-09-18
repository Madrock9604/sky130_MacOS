#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'


EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
SRC_DIR="${SRC_DIR:-$EDA_ROOT/src}"
BIN_DIR="$EDA_ROOT/bin"
XSCHEM_REF="${XSCHEM_REF:-master}"


if command -v brew >/dev/null 2>&1; then eval "$($(command -v brew) shellenv)"; fi
BREW_PREFIX=$(brew --prefix)


mkdir -p "$SRC_DIR" "$BIN_DIR"
cd "$SRC_DIR"


if [ ! -d xschem ]; then
echo "[INFO] Cloning xschem…"
git clone --depth=1 --branch "$XSCHEM_REF" https://github.com/StefanSchippers/xschem.git
fi
cd xschem


# Prefer Brew Tcl/Tk and XQuartz
export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig${PKG_CONFIG_PATH:+:}$PKG_CONFIG_PATH"
export CPPFLAGS="-I$BREW_PREFIX/opt/tcl-tk/include -I/opt/X11/include ${CPPFLAGS:-}"
export LDFLAGS="-L$BREW_PREFIX/opt/tcl-tk/lib -L/opt/X11/lib ${LDFLAGS:-}"


# xschem provides a standard autotools configure
./configure \
--prefix="$EDA_ROOT/opt/xschem" \
--with-tcl="$BREW_PREFIX/opt/tcl-tk" \
--with-tk="$BREW_PREFIX/opt/tcl-tk" \
--x-includes=/opt/X11/include \
--x-libraries=/opt/X11/lib


make -j"$(/usr/sbin/sysctl -n hw.ncpu)"
make install


ln -sf "$EDA_ROOT/opt/xschem/bin/xschem" "$BIN_DIR/xschem"


# Version check (xschem prints version banner)
"$EDA_ROOT/opt/xschem/bin/xschem" -v || echo "[OK ] xschem installed."
