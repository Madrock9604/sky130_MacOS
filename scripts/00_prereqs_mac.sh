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
log "Writing isolated environment activator: $ACTIVATE"
cat >"$ACTIVATE" <<'EOF'
# Source this file to enter the EDA env
# $ source ~/.eda/sky130/activate


# Detect Homebrew
if command -v brew >/dev/null 2>&1; then
eval "$($(command -v brew) shellenv)"
fi
export EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
export PDK_ROOT="${PDK_ROOT:-$EDA_ROOT/pdks}"
export PDK="${PDK:-sky130A}"


# Prefer Brew's tcl-tk and XQuartz headers/libs for builds
ok "Prereqs done. You can now run component installers."
