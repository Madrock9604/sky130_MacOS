#!/usr/bin/env bash
# macOS prereqs for Magic/xschem/ngspice/open_pdks (Apple Silicon or Intel)
# - Xcode CLT
# - Homebrew install + PATH wiring (current shell + future shells)
# - XQuartz (X11 fallback)
# - Tcl/Tk 8.6 (for Magic Aqua GUI)
# - Common build deps (cairo, pkg-config, gtk+3, gawk, make, wget, python, readline)
set -euo pipefail

ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"

LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/prereqs.log"
exec > >(tee -a "$LOG") 2>&1

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }
trap 'fail "Prereqs failed at line $LINENO (see $LOG)"' ERR

bold "Prerequisites (macOS) — starting…"

# --- 0) Base folders ---
EDA_BASE="${EDA_BASE:-$HOME/.eda/sky130_dev}"
mkdir -p "$EDA_BASE" "$HOME/src-eda"
info "Base folders at $EDA_BASE and $HOME/src-eda"

# --- 1) Xcode Command Line Tools ---
if ! xcode-select -p >/dev/null 2>&1; then
  info "Installing Xcode Command Line Tools… (follow on-screen prompts)"
  xcode-select --install || true
  # Wait until CLT exists (user may have clicked “Install” in dialog)
  for i in {1..30}; do
    xcode-select -p >/dev/null 2>&1 && break
    sleep 5
  done
fi
ok "Xcode CLT present."

# --- 2) Homebrew install & PATH wiring (works in non-interactive shells) ---
BREW_BIN=""
if [ -x "$DEFAULT_BREW_PREFIX/bin/brew" ]; then
  BREW_BIN="$DEFAULT_BREW_PREFIX/bin/brew"
elif [ -x /opt/homebrew/bin/brew ]; then
  BREW_BIN="/opt/homebrew/bin/brew"
elif [ -x /usr/local/bin/brew ]; then
  BREW_BIN="/usr/local/bin/brew"
fi

if [ -z "$BREW_BIN" ]; then
  info "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Re-detect
  if [ -x "$DEFAULT_BREW_PREFIX/bin/brew" ]; then
    BREW_BIN="$DEFAULT_BREW_PREFIX/bin/brew"
  elif [ -x /opt/homebrew/bin/brew ]; then
    BREW_BIN="/opt/homebrew/bin/brew"
  elif [ -x /usr/local/bin/brew ]; then
    BREW_BIN="/usr/local/bin/brew"
  else
    fail "Homebrew installed but not found on expected paths."
  fi
fi
# Load brew env into THIS shell
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# Persist for future zsh shells (macOS uses .zprofile for PATH by default)
ZP="$HOME/.zprofile"; ZR="$HOME/.zshrc"
if ! grep -Fq 'brew shellenv' "$ZP" 2>/dev/null; then
  {
    echo ''
    echo '# Homebrew (added by 00_prereqs_mac.sh)'
    echo "eval \"\$($BREW_BIN shellenv)\""
  } >> "$ZP"
fi
if ! grep -Fq 'brew shellenv' "$ZR" 2>/dev/null; then
  {
    echo ''
    echo '# Homebrew (added by 00_prereqs_mac.sh)'
    echo "eval \"\$($BREW_BIN shellenv)\""
  } >> "$ZR"
fi

# --- 3) XQuartz (X11 server) ---
if [ ! -d /Applications/Utilities/XQuartz.app ]; then
  info "Installing XQuartz…"
  brew install --cask xquartz
else
  info "XQuartz already present."
fi
ok "XQuartz ok."

# --- 4) Tcl/Tk 8.6 (Aqua) for Magic GUI ---
# Prefer tk 8.6 to avoid Tk 9 GUI breakage with Magic openwrapper
if ! brew list --versions tcl-tk@8.6 >/dev/null 2>&1 && ! brew list --versions tcl-tk@8 >/dev/null 2>&1; then
  info "Installing Tcl/Tk 8.6…"
  brew install tcl-tk@8.6 || brew install tcl-tk@8
fi
TK_PREFIX="$(brew --prefix tcl-tk@8.6 2>/dev/null || brew --prefix tcl-tk@8 2>/dev/null || true)"
if [ -z "$TK_PREFIX" ] || [ ! -x "$TK_PREFIX/bin/wish8.6" ]; then
  fail "Tcl/Tk 8.6 not found after install."
fi
ok "Tcl/Tk 8.6 at $TK_PREFIX"

# --- 5) Common build deps for magic/xschem/open_pdks/ngspice ---
# (xschem needs gtk+3; magic uses cairo/tcl-tk; open_pdks uses gawk/wget/make/python)
DEPS=( cairo pkg-config gawk wget make python readline gtk+3 )
for p in "${DEPS[@]}"; do
  if ! brew list --versions "$p" >/dev/null 2>&1; then
    info "Installing $p…"
    brew install "$p"
  fi
done
ok "Core build deps installed."

# --- 6) Aqua GUI helper: ensure wish8.6 available via env hint (for our scripts) ---
ACTIVATE="$EDA_BASE/activate"
mkdir -p "$EDA_BASE"
if ! grep -q 'wish8\.6' "$ACTIVATE" 2>/dev/null; then
  {
    echo '# Tk/Aqua: prefer Tk 8.6 for Magic GUI'
    echo "export WISH=\"$TK_PREFIX/bin/wish8.6\""
  } >> "$ACTIVATE"
fi

# --- 7) Final info ---
ok "Prerequisites complete."
echo "Next steps:"
echo "  - Open a NEW terminal (or 'source ~/.zprofile') so brew is on PATH."
echo "  - Then run:   bash scripts/20_magic.sh"
echo "  - GUI (Aqua) test:  \${WISH:-$TK_PREFIX/bin/wish8.6} \$HOME/.eda/sky130_dev/lib/magic/tcl/magic.tcl -d null -T scmos -rcfile /dev/null -wrapper"
