#!/usr/bin/env bash
# macOS prereqs for Magic build (brew + Tk 8.6 + common deps).
set -euo pipefail

ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
mkdir -p "$LOG_DIR" "$EDA_PREFIX"
LOG="$LOG_DIR/prereqs.log"
exec > >(tee -a "$LOG") 2>&1

info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }

info "Prereqs start…"

# 0) Xcode CLT
if ! xcode-select -p >/dev/null 2>&1; then
  info "Installing Xcode Command Line Tools (follow dialog)…"
  xcode-select --install || true
  for i in {1..30}; do xcode-select -p >/dev/null 2>&1 && break; sleep 5; done
fi
ok "Xcode CLT present"

# 1) Homebrew (absolute path; works without PATH)
BREW_BIN=""
for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$p" ] && BREW_BIN="$p" && break
done
if [ -z "$BREW_BIN" ]; then
  info "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && BREW_BIN="$p" && break
  done
  [ -n "$BREW_BIN" ] || fail "Homebrew installed but not found."
fi
# Load brew env into THIS shell
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# 2) Core deps (safe for set -u)
need_pkgs=(cairo pkg-config gawk make)
if ((${#need_pkgs[@]})); then
  for pkg in "${need_pkgs[@]}"; do
    brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"
  done
fi
ok "Common deps installed"

# 3) Install a **Tk 8.6** keg (Homebrew exposes as tcl-tk@8; plain tcl-tk may be 9.x)
brew list --versions tcl-tk@8 >/dev/null 2>&1 || brew install tcl-tk@8 || true

# Resolve a keg that is truly 8.6
TK86_PREFIX=""
for cand in "$(brew --prefix tcl-tk@8 2>/dev/null)" "$(brew --prefix tcl-tk 2>/dev/null)"; do
  [ -n "$cand" ] || continue
  if [ -f "$cand/lib/tclConfig.sh" ] && grep -q 'TCL_VERSION=8\.6' "$cand/lib/tclConfig.sh"; then
    TK86_PREFIX="$cand"; break
  fi
done
[ -n "$TK86_PREFIX" ] || fail "Tcl/Tk 8.6 keg not found. Try: brew reinstall tcl-tk@8"
ok "Tk 8.6 at $TK86_PREFIX"

# 4) Hint wish8.6 in activate for Aqua GUI
ACT="$EDA_PREFIX/activate"
mkdir -p "$EDA_PREFIX"
grep -q 'wish8\.6' "$ACT" 2>/dev/null || {
  {
    echo '# Prefer Tk 8.6 for Magic Aqua GUI'
    echo "export WISH=\"$TK86_PREFIX/bin/wish8.6\""
  } >> "$ACT"
}
ok "Activate updated: $ACT"

ok "Prereqs complete. Next: bash scripts/20_magic.sh"
