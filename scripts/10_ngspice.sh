#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'


EDA_ROOT="${EDA_ROOT:-$HOME/.eda/sky130}"
BIN_DIR="$EDA_ROOT/bin"


# Bring brew into PATH for this non-interactive shell
if command -v brew >/dev/null 2>&1; then eval "$($(command -v brew) shellenv)"; fi


echo "[INFO] Installing ngspice via Homebrew…"
brew install ngspice


mkdir -p "$BIN_DIR"
ln -sf "$(command -v ngspice)" "$BIN_DIR/ngspice"


echo "[OK ] ngspice installed: $(ngspice -v | head -n1)"
