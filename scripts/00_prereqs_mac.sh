#!/usr/bin/env bash
# macOS prereqs for Magic build (installs everything; no manual steps).
# - Installs Homebrew (if missing) and loads it into THIS shell
# - Installs core deps (git, cairo, pkg-config, gawk, make, wget)
# - Installs Tcl/Tk 8.6 (Homebrew keg: tcl-tk@8) and verifies using wish8.6
# - Writes WISH=…/wish8.6 into ~/.eda/sky130_dev/activate
# - Exports CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH so builds can find the keg-only Tk

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
err(){ printf "❌ %s\n" "$*\n" >&2; exit 1; }

info "Prereqs start…"

# 0) Xcode CLT
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
  [ -n "$BREW_BIN" ] || err "Homebrew installed but not found."
fi
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# 2) Core deps
NEEDED=(git cairo pkg-config gawk make wget)
for pkg in "${NEEDED[@]}"; do
  brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
ok "Common deps installed"

# 3) Install & VERIFY Tcl/Tk 8.6 via wish8.6 (keg-only: tcl-tk@8)
brew update >/dev/null
brew list --versions tcl-tk@8 >/dev/null 2>&1 || brew install tcl-tk@8 || true

TK86_PREFIX="$(brew --prefix tcl-tk@8 2>/dev/null || true)"
if [ -z "$TK86_PREFIX" ] || [ ! -x "$TK86_PREFIX/bin/wish8.6" ]; then
  info "Reinstalling tcl-tk@8 to provide wish8.6…"
  brew reinstall tcl-tk@8 || true
  TK86_PREFIX="$(brew --prefix tcl-tk@8 2>/dev/null || true)"
fi

# Final verification: ask wish8.6 its patchlevel
TK_VER=""
if [ -x "$TK86_PREFIX/bin/wish8.6" ]; then
  TK_VER="$("$TK86_PREFIX/bin/wish8.6" <<< 'puts [info patchlevel]; exit' 2>/dev/null || true)"
fi
[ -n "$TK86_PREFIX" ] && [[ "$TK_VER" == 8.6.* ]] || err "Tcl/Tk 8.6 not usable after install (wish8.6 missing/wrong). See $LOG"
ok "Tk $TK_VER at $TK86_PREFIX"

# 4) Export flags so builds find keg-only Tk (helpful for later scripts)
export CPPFLAGS="-I$TK86_PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$TK86_PREFIX/lib ${LDFLAGS:-}"
export PKG_CONFIG_PATH="$TK86_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# 5) Persist brew shellenv for future shells (idempotent)
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

# 6) Teach your EDA activate file about wish8.6 (Aqua GUI)
ACT="$EDA_PREFIX/activate"
mkdir -p "$EDA_PREFIX"
grep -q 'wish8\.6' "$ACT" 2>/dev/null || {
  {
    echo '# Prefer Tk 8.6 for Magic Aqua GUI'
    echo "export WISH=\"$TK86_PREFIX/bin/wish8.6\""
    echo "export CPPFLAGS=\"-I$TK86_PREFIX/include \$CPPFLAGS\""
    echo "export LDFLAGS=\"-L$TK86_PREFIX/lib \$LDFLAGS\""
    echo "export PKG_CONFIG_PATH=\"$TK86_PREFIX/lib/pkgconfig:\$PKG_CONFIG_PATH\""
  } >> "$ACT"
}

ok "Prereqs complete. Tk $TK_VER ready; WISH exported in $ACT"
