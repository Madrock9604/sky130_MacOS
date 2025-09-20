# --- Homebrew install & PATH setup (robust) ---
ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"

BREW_BIN=""
if [ -x "$DEFAULT_BREW_PREFIX/bin/brew" ]; then
  BREW_BIN="$DEFAULT_BREW_PREFIX/bin/brew"
elif [ -x /opt/homebrew/bin/brew ]; then
  BREW_BIN="/opt/homebrew/bin/brew"
elif [ -x /usr/local/bin/brew ]; then
  BREW_BIN="/usr/local/bin/brew"
fi

if [ -z "$BREW_BIN" ]; then
  echo "[INFO] Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Re-detect after install
  if [ -x "$DEFAULT_BREW_PREFIX/bin/brew" ]; then
    BREW_BIN="$DEFAULT_BREW_PREFIX/bin/brew"
  elif [ -x /opt/homebrew/bin/brew ]; then
    BREW_BIN="/opt/homebrew/bin/brew"
  elif [ -x /usr/local/bin/brew ]; then
    BREW_BIN="/usr/local/bin/brew"
  else
    echo "[ERR ] Homebrew installed but not found on expected paths"; exit 1
  fi
fi

# Load brew env into THIS shell (non-interactive safe)
eval "$("$BREW_BIN" shellenv)"

# Persist for future shells (zsh on macOS reads ~/.zprofile for PATH)
ZP="$HOME/.zprofile"; ZR="$HOME/.zshrc"
if ! grep -Fq 'brew shellenv' "$ZP" 2>/dev/null; then
  {
    echo ''
    echo '# Homebrew (added by 00_prereqs_mac.sh)'
    echo "eval \"$(/usr/bin/printf '%q' "$("$BREW_BIN" shellenv)")\""
  } >> "$ZP"
fi
# Optional: also add to .zshrc for users who rely on it
if ! grep -Fq 'brew shellenv' "$ZR" 2>/dev/null; then
  {
    echo ''
    echo '# Homebrew (added by 00_prereqs_mac.sh)'
    echo "eval \"$(/usr/bin/printf '%q' "$("$BREW_BIN" shellenv)")\""
  } >> "$ZR"
fi

echo "[ OK ] Homebrew ready at: $BREW_BIN"
