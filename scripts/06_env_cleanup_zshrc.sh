#!/usr/bin/env bash
# Safely remove conflicting PATH/EDA lines from ~/.zshrc (keeps the activate line).
# Non-interactive, creates timestamped backup.

set -euo pipefail

SHELL_RC="${SHELL_RC:-$HOME/.zshrc}"
EDA_PREFIX_DEFAULT="$HOME/.eda/sky130_dev"
EDA_PREFIX="${EDA_PREFIX:-$EDA_PREFIX_DEFAULT}"
ACTIVATE_LINE="[ -f \"$EDA_PREFIX/activate\" ] && source \"$EDA_PREFIX/activate\""

[ -f "$SHELL_RC" ] || { echo "No $SHELL_RC found. Nothing to clean."; exit 0; }

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP="${SHELL_RC}.bak.$TS"
cp "$SHELL_RC" "$BACKUP"
echo "Backup saved: $BACKUP"

# Build a new zshrc filtering out problematic lines
TMP="$(mktemp)"
awk -v eda="$EDA_PREFIX" '
  # 1) Drop any PATH exports that point into ~/.eda/*/bin
  $0 ~ /(^|\s)export[[:space:]]+PATH=.*\.eda\/[^:]*\/bin/ { next }

  # 2) Drop our previous “Added by …” blocks (old installers)
  $0 ~ /Added by 20_magic\.sh/ { next }
  $0 ~ /Added by 30_xschem\.sh/ { next }
  $0 ~ /Added by 40_sky130pdk\.sh/ { next }
  $0 ~ /Added by 05_env_activate\.sh/ { next }

  # 3) Drop explicit EDA envs tied to ~/.eda/* to avoid conflicts
  $0 ~ /^export[[:space:]]+PDK_ROOT=.*\.eda\// { next }
  $0 ~ /^export[[:space:]]+PDK=.*sky130/ { next }
  $0 ~ /^export[[:space:]]+EDA_PREFIX=.*\.eda\// { next }

  # 4) Drop direct aliases or hardcoded magic/xschem to ~/.eda paths
  $0 ~ /^alias[[:space:]]+magic=.*\.eda\// { next }
  $0 ~ /^alias[[:space:]]+xschem=.*\.eda\// { next }

  # Otherwise keep line
  { print $0 }
' "$SHELL_RC" > "$TMP"

# Ensure a single activate line exists near end
if ! grep -Fq "$ACTIVATE_LINE" "$TMP"; then
  {
    echo ""
    echo "# Added by 05_env_activate.sh (EDA toolchain)"
    echo "$ACTIVATE_LINE"
  } >> "$TMP"
fi

mv "$TMP" "$SHELL_RC"
echo "Cleaned $SHELL_RC. Old file at $BACKUP"
echo "Done."
