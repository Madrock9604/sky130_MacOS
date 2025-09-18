#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'


# ===== Config =====
EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
SRC_DIR="${SRC_DIR:-$EDA_ROOT/src}"
BIN_DIR="$EDA_ROOT/bin"
AUTO_ADD_SHELL_RC="${AUTO_ADD_SHELL_RC:-0}" # set to 1 to auto-add 'activate' sourcing to ~/.zshrc


# ===== UI helpers =====
RED=$(tput setaf 1 || true); GREEN=$(tput setaf 2 || true); YELLOW=$(tput setaf 3 || true); BLUE=$(tput setaf 4 || true); BOLD=$(tput bold || true); RESET=$(tput sgr0 || true)
log(){ echo "${BLUE}[INFO]${RESET} $*"; }
warn(){ echo "${YELLOW}[WARN]${RESET} $*"; }
ok(){ echo "${GREEN}[ OK ]${RESET} $*"; }
err(){ echo "${RED}[ERR ]${RESET} $*" >&2; }
trap 'err "Install failed on line $LINENO"' ERR


log "Creating base folders at $EDA_ROOT …"
mkdir -p "$SRC_DIR" "$BIN_DIR" "$EDA_ROOT/opt" "$EDA_ROOT/tmp"


# ===== Xcode CLT =====
if ! xcode-select -p >/dev/null 2>&1; then
log "Installing Xcode Command Line Tools…"
xcode-select --install || warn "If a GUI dialog appears, complete it manually, then rerun."
else
ok "Xcode Command Line Tools present."
fi


# ===== Homebrew =====
if ! command -v brew >/dev/null 2>&1; then
log "Installing Homebrew…"
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
# shellcheck disable=SC2046
eval "$($(command -v brew) shellenv)"
BREW_PREFIX=$(brew --prefix)
ok "Homebrew at $BREW_PREFIX"


log "Installing prerequisites via Homebrew (no MacPorts)…"
brew update
brew install \
git wget curl \
pkg-config autoconf automake libtool cmake make \
gawk bison flex \
readline \
cairo \
tcl-tk \
gnuplot


# X11 (needed by magic/xschem)
brew install --cask xquartz || true


ok "Base packages installed."


# ===== Activate script (keeps env isolated; no global changes unless opted in) =====
ACTIVATE="$EDA_ROOT/activate"
echo "[INFO] Writing isolated environment activator: $ACTIVATE"
cat >"$ACTIVATE" <<'EOF'
# Source this file to enter the EDA env
#   $ source ~/.eda/sky130/activate

# Detect Homebrew
if command -v brew >/dev/null 2>&1; then
  eval "$($(command -v brew) shellenv)"
fi

export EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
export PDK_ROOT="$EDA_ROOT/pdks"     # force isolated PDK path
export PDK="${PDK:-sky130A}"

# Prefer Brew's Tcl/Tk and XQuartz headers/libs for builds
BREW_PREFIX=$(brew --prefix 2>/dev/null || echo "/opt/homebrew")
export PATH="$EDA_ROOT/bin:$PATH"
# Configure with Tcl/Tk from Homebrew and XQuartz headers/libs
# (Works with: set -euo pipefail)
if [ -n "${PKG_CONFIG_PATH-}" ]; then
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig:$PKG_CONFIG_PATH"
else
  export PKG_CONFIG_PATH="$BREW_PREFIX/opt/tcl-tk/lib/pkgconfig"
fi

export CPPFLAGS="-I$BREW_PREFIX/opt/tcl-tk/include -I/opt/X11/include ${CPPFLAGS-}"
export LDFLAGS="-L$BREW_PREFIX/opt/tcl-tk/lib -L/opt/X11/lib ${LDFLAGS-}"


# X11 display; XQuartz usually sets this automatically
export DISPLAY="${DISPLAY:-:0}"

# Magic / Xschem integration with SKY130
export MAGICRC="$PDK_ROOT/$PDK/libs.tech/magic/$PDK.magicrc"
export XSCHEM_LIBRARY_PATH="$PDK_ROOT/$PDK/libs.tech/xschem"

# Handy aliases (do not overwrite system installs)
alias magic-sky130='magic -rcfile "$MAGICRC"'
alias xschem-sky130='XSCHEM_LIBRARY_PATH="$XSCHEM_LIBRARY_PATH" xschem'

# Quick checks (helpers)
magic_check(){ command -v magic >/dev/null && magic -dnull -noconsole -rcfile /dev/null -e 'quit' || echo "magic not found"; }
ngspice_check(){ command -v ngspice >/dev/null && ngspice -v || echo "ngspice not found"; }
xschem_check(){ command -v xschem >/dev/null && xschem -v || echo "xschem not found"; }
EOF
chmod +x "$ACTIVATE"

