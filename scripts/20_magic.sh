#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Magic via Homebrew + XQuartz
# Wires into ~/.eda/sky130/activate and ~/.eda/sky130/bin/magic
# No upstream source repos used.
# ------------------------------------------------------------

# Allow overrides, but default to your env layout
PREFIX="${PREFIX:-$HOME/.eda/sky130}"
BIN_DIR="$PREFIX/bin"
ACTIVATE="$HOME/.eda/sky130/activate"

echo "[INFO] Using PREFIX: $PREFIX"
mkdir -p "$BIN_DIR"
mkdir -p "$(dirname "$ACTIVATE")"

# --- Require macOS + Homebrew ---
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "[ERR ] This script is intended for macOS." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "[ERR ] Homebrew is not installed."
  echo "      Install it first, then re-run:"
  echo '      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi

# --- Install dependencies ---
echo "[INFO] Updating Homebrew…"
brew update

echo "[INFO] Installing Magic (package: magic)…"
brew install magic || true  # ok if already installed

echo "[INFO] Installing XQuartz (X11 server)…"
brew install --cask xquartz || true  # ok if already installed

# --- Find Magic binary installed by Homebrew ---
if command -v magic >/dev/null 2>&1; then
  MAGIC_BIN="$(command -v magic)"
else
  # Fallback: look inside the keg
  MAGIC_BIN="$(brew --prefix magic 2>/dev/null)/bin/magic"
fi

if [[ ! -x "${MAGIC_BIN}" ]]; then
  echo "[ERR ] Could not locate Magic binary after brew install." >&2
  exit 1
fi

echo "[INFO] Using magic binary: ${MAGIC_BIN}"

# --- Create a wrapper in your env bin (so your PATH wins) ---
WRAPPER="$BIN_DIR/magic"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# Wrapper to run Homebrew Magic inside the sky130 environment.
# Prefer XQuartz/X11 graphics; users can still pass -dnull for headless.

# If XQuartz app is present but not running, optionally start it quietly.
if [[ -d "/Applications/Utilities/XQuartz.app" ]] && ! pgrep -x XQuartz >/dev/null 2>&1; then
  open -gj /Applications/Utilities/XQuartz.app 2>/dev/null || true
fi

exec "${MAGIC_BIN}" "\$@"
EOF

chmod +x "$WRAPPER"
echo "[INFO] Wrapper created at: $WRAPPER"

# --- Write/patch the activate file so PATH includes your bin ---
if [[ ! -f "$ACTIVATE" ]]; then
  cat > "$ACTIVATE" <<'EOF'
# sky130 environment activation
# Adds ~/.eda/sky130/bin to PATH so repo-installed tools are found first.

# Avoid duplicate PATH entries
case ":$PATH:" in
  *":$HOME/.eda/sky130/bin:"*) ;;
  *) export PATH="$HOME/.eda/sky130/bin:$PATH" ;;
esac
EOF
  echo "[INFO] Wrote env file: $ACTIVATE"
else
  # Ensure BIN_DIR is on PATH in the existing activate file
  if ! grep -q '\/\.eda\/sky130\/bin' "$ACTIVATE"; then
    cat >> "$ACTIVATE" <<'EOF'

# Ensure sky130 bin is on PATH
case ":$PATH:" in
  *":$HOME/.eda/sky130/bin:"*) ;;
  *) export PATH="$HOME/.eda/sky130/bin:$PATH" ;;
case
EOF
    echo "[INFO] Updated env file: $ACTIVATE"
  fi
fi

echo "[INFO] Done."
echo "[INFO] Next steps:"
echo "  1) source \"$ACTIVATE\""
echo "  2) Run GUI test: magic"
echo "     (If a window doesn't appear, open XQuartz first: open -a XQuartz)"
echo "  3) Headless test (no GUI): magic -dnull -noconsole -nowindow -norcfile -T minimum - <<<'quit'"
