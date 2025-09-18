#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'


# This orchestrator runs everything in order. It DOES NOT modify your shell rc.
# You can optionally export AUTO_ADD_SHELL_RC=1 before running 00_prereqs_mac.sh if you want auto-activation.


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


bash "$SCRIPT_DIR/00_prereqs_mac.sh"
bash "$SCRIPT_DIR/10_ngspice.sh"
bash "$SCRIPT_DIR/20_magic.sh"
bash "$SCRIPT_DIR/30_xschem.sh"
bash "$SCRIPT_DIR/40_sky130pdk.sh"


echo "\n[OK ] All done. Enter the env with: source ~/.eda/sky130/activate"
echo "Then try: ngspice -v | head -n1; magic-sky130; xschem-sky130"
