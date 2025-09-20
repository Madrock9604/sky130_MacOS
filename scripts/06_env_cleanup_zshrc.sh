#!/usr/bin/env bash
# Remove any ~/.eda/* PATH/env lines from common rc files and keep only the activate hook.

set -euo pipefail

EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
ACTIVATE_LINE="[ -f \"$EDA_PREFIX/activate\" ] && source \"$EDA_PREFIX/activate\""

RC_FILES=(
  "$HOME/.zshrc"
  "$HOME/.zprofile"
  "$HOME/.zshenv"
  "$HOME/.bashrc"
  "$HOME/.bash_profile"
  "$HOME/.profile"
)

clean_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local ts backup tmp
  ts="$(date +%Y%m%d_%H%M%S)"
  backup="${f}.bak.${ts}"
  cp "$f" "$backup"
  echo "Backup saved: $backup"

  tmp="$(mktemp)"
  awk -v home="$HOME" '
    # Drop any PATH export/assignment that includes ~/.eda/*/bin anywhere
    $0 ~ /(export[[:space:]]+PATH=|PATH=)/ && $0 ~ home"/.eda/.*/bin" { next }

    # Drop explicit EDA envs tied to ~/.eda/*
    $0 ~ /^export[[:space:]]+PDK_ROOT=.*\.eda\// { next }
    $0 ~ /^export[[:space:]]+PDK=.*sky130/       { next }
    $0 ~ /^export[[:space:]]+EDA_PREFIX=.*\.eda\// { next }

    # Drop aliases pointing to ~/.eda/*
    $0 ~ /^alias[[:space:]]+magic=.*\.eda\//  { next }
    $0 ~ /^alias[[:space:]]+xschem=.*\.eda\// { next }

    # Drop previous auto-added lines from our installers
    $0 ~ /Added by 05_env_activate\.sh/ { next }
    $0 ~ /Added by 20_magic\.sh/        { next }
    $0 ~ /Added by 30_xschem\.sh/       { next }
    $0 ~ /Added by 40_sky130pdk\.sh/    { next }

    # Drop older activate hook lines pointing to other ~/.eda prefixes
    $0 ~ /source[[:space:]]+.*\.eda\/.*\/activate/ && $0 !~ /sky130_dev\/activate/ { next }

    { print $0 }
  ' "$f" > "$tmp"

  # Ensure exactly one activate line at the end
  grep -Fq "$ACTIVATE_LINE" "$tmp" || {
    {
      echo ""
      echo "# Added by 05_env_activate.sh (EDA toolchain)"
      echo "$ACTIVATE_LINE"
    } >> "$tmp"
  }

  mv "$tmp" "$f"
  echo "Cleaned: $f"
}

for rc in "${RC_FILES[@]}"; do
  clean_file "$rc"
done

echo "Done. Open a NEW terminal or run: source ~/.zshrc"
