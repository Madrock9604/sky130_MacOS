#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'


EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
SRC_DIR="${SRC_DIR:-$EDA_ROOT/src}"
PDK_ROOT="${PDK_ROOT:-$EDA_ROOT/pdks}"
OPEN_PDKS_REF="${OPEN_PDKS_REF:-master}"


if command -v brew >/dev/null 2>&1; then eval "$($(command -v brew) shellenv)"; fi


mkdir -p "$SRC_DIR" "$PDK_ROOT"
cd "$SRC_DIR"


if [ ! -d open_pdks ]; then
echo "[INFO] Cloning open_pdks…"
git clone --depth=1 --branch "$OPEN_PDKS_REF" https://github.com/RTimothyEdwards/open_pdks.git
fi
cd open_pdks


# Build SKY130A and xschem libraries
./configure \
--prefix="$PDK_ROOT" \
--enable-sky130-pdk \
--enable-xschem-sky130


make -j"$(/usr/sbin/sysctl -n hw.ncpu)"
make install


# Quick sanity checks
MAGICRC="$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc"
XSLIB="$PDK_ROOT/sky130A/libs.tech/xschem"


[ -f "$MAGICRC" ] && echo "[OK ] Found $MAGICRC" || { echo "[ERR] sky130A magicrc missing"; exit 1; }
[ -d "$XSLIB" ] && echo "[OK ] Found Xschem libs at $XSLIB" || { echo "[ERR] xschem libs missing"; exit 1; }
