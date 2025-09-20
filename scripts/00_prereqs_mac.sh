#!/usr/bin/env bash
# macOS prereqs for Magic build (installs everything needed).
# - Installs Homebrew (if missing) and wires it into this shell.
# - Installs core build deps.
# - Installs a TRUE Tcl/Tk 8.6 keg (tcl-tk@8) and verifies it by reading tclConfig.sh.
# - Exports WISH=…/wish8.6 in ~/.eda/sky130_dev/activate so Aqua GUI works.
set -euo pipefail

ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"
EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
mkdir -p "$LOG_DIR" "$EDA_PREFIX"
LOG="$LOG_DIR/prereqs.log"
exec > >(tee -a "$LOG") 2>&1

info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }

info "Prereqs start…"

# 0) Xcode CLT (install if missing)
if ! xcode-select -p >/dev/null 2>&1; then
  info "Installing Xcode Command Line Tools (follow dialog)…"
  xcode-select --install || true
  for i in {1..30}; do xcode-select -p >/dev/null 2>&1 && break; sleep 5; done
fi
ok "Xcode CLT present"

# 1) Homebrew (install if missing) + load into THIS shell
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
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# 2) Core deps (install if missing)
need_pkgs=(git cairo pkg-config gawk make wget)
for pkg in "${need_pkgs[@]}"; do
  brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
ok "Common deps installed"

# 3) Install a TRUE Tcl/Tk 8.6 keg (and verify)
brew update
# Ensure the @8 keg is present (this is 8.6 on Homebrew)
brew list --versions tcl-tk@8 >/dev/null 2>&1 || brew install tcl-tk@8 || true

find_tk86_prefix() {
  for cand in "$(brew --prefix tcl-tk@8 2>/dev/null)" "$(brew --prefix tcl-tk 2>/dev/null)"; do
    [ -n "$cand" ] || continue
    for cfg in "$cand/lib/tclConfig.sh" "$cand/lib/tcl8.6/tclConfig.sh"; do
      if [ -f "$cfg" ] && grep -q 'TCL_VERSION=8\.6' "$cfg"; then
        echo "$cand"; return 0
      fi
    done
  done
  return 1
}

TK86_PREFIX="$(find_tk86_prefix || true)"
if [ -z "$TK86_PREFIX" ]; then
  info "Reinstalling tcl-tk@8 to ensure 8.6 symbols…"
  brew reinstall tcl-tk@8 || true
  TK86_PREFIX="$(find_tk86_prefix || true)"
fi

[ -n "$TK86_PREFIX" ] || fail "Tcl/Tk 8.6 keg not found after install. See $LOG"
[ -x "$TK86_PREFIX/bin/wish8.6" ] || fail "wish8.6 not found under $TK86_PREFIX"
ok "Tk 8.6 at $TK86_PREFIX"

# 4) Persist brew shellenv (future shells)
ZP="$HOME/.zprofile"; ZR="$HOME/.zshrc"
grep -Fq 'brew shellenv' "$ZP" 2>/dev/null || {
  {
    echo ''
    echo '# Homebrew (added by 00_prereqs_mac.sh)'
    echo "eval \"\$($BREW_BIN shellenv)\""
  } >> "$ZP"
}
grep -Fq 'brew shellenv' "$ZR" 2>/dev/null || {
  {
    echo ''
    echo '# Homebrew (added by 00_prereqs_mac.sh)'
    echo "eval \"\$($BREW_BIN shellenv)\""
  } >> "$ZR"
}

# 5) Add wish8.6 hint to activate for Aqua GUI
ACT="$EDA_PREFIX/activate"
mkdir -p "$EDA_PREFIX"
grep -q 'wish8\.6' "$ACT" 2>/dev/null || {
  {
    echo '# Prefer Tk 8.6 for Magic Aqua GUI'
    echo "export WISH=\"$TK86_PREFIX/bin/wish8.6\""
  } >> "$ACT"
}

ok "Prereqs complete. Tk 8.6 ready and WISH exported in $ACT"
