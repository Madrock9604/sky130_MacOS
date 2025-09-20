#!/usr/bin/env bash
# Create and register a reusable 'activate' for the isolated toolchain env.
set -euo pipefail

ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"

EDA_PREFIX="${PREFIX:-$HOME/.eda/sky130_dev}"
BREW_PREFIX="${BREW_PREFIX:-$DEFAULT_BREW_PREFIX}"
ACTIVATE_PATH="$EDA_PREFIX/activate"
SHELL_RC="${SHELL_RC:-$HOME/.zshrc}"

mkdir -p "$EDA_PREFIX"

cat > "$ACTIVATE_PATH" <<'EOF'
# ---- EDA isolated environment ----
export EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"

# Binaries
export PATH="$EDA_PREFIX/bin:${PATH}"

# PDK env (ok even if not installed yet)
export PDK_ROOT="${PDK_ROOT:-$EDA_PREFIX/pdks}"
export PDK="${PDK:-sky130A}"

# X11 / XQuartz: prefer local display and allow local clients
if [ -z "${DISPLAY:-}" ] || [[ "$DISPLAY" != :* ]]; then
  export DISPLAY=:0
fi
if command -v xhost >/dev/null 2>&1; then
  xhost +localhost >/dev/null 2>&1 || true
fi

echo "[EDA] EDA_PREFIX=$EDA_PREFIX  PDK_ROOT=$PDK_ROOT  PDK=$PDK  DISPLAY=${DISPLAY:-unset}"
# ----------------------------------
EOF

# Ensure XQuartz is installed (prereqs script should have done this)
if [ ! -d /Applications/Utilities/XQuartz.app ]; then
  echo "❌ XQuartz not found. Run scripts/00_prereqs_mac.sh first." >&2
  exit 1
fi

# Make shells auto-source the activate (idempotent)
grep -qF "$ACTIVATE_PATH" "$SHELL_RC" 2>/dev/null || {
  {
    echo ""
    echo "# Added by 05_env_activate.sh (EDA toolchain)"
    echo "[ -f \"$ACTIVATE_PATH\" ] && source \"$ACTIVATE_PATH\""
  } >> "$SHELL_RC"
}

echo "✅ Created $ACTIVATE_PATH and registered it in $SHELL_RC"
echo "👉 Open a NEW terminal (or run: source \"$SHELL_RC\") to load env."
