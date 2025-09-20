#!/usr/bin/env bash
# Install Magic from source (arm64/macOS) without touching existing setups
# Usage: bash scripts/20_magic.sh

set -euo pipefail

# -------- Config (override via env) --------
PREFIX="${PREFIX:-$HOME/.eda/sky130_dev}"        # <-- separate from any working/student install
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"      # Intel Macs: /usr/local
X11_PREFIX="${X11_PREFIX:-/opt/X11}"             # XQuartz default
SRC_DIR="${SRC_DIR:-$HOME/src-eda}"
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
MAGIC_TAG="${MAGIC_TAG:-master}"                 # e.g., "8.3.495" if you want a fixed tag
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# -------- Internals --------
mkdir -p "$SRC_DIR" "$LOG_DIR"
LOG="$LOG_DIR/magic_install.log"
STAMP_DIR="$PREFIX/.stamps"
mkdir -p "$STAMP_DIR"

exec > >(tee -a "$LOG") 2>&1

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }

trap 'fail "Magic install failed at line $LINENO. See $LOG"' ERR

bold "Magic installer"
info "PREFIX=$PREFIX"
info "BREW_PREFIX=$BREW_PREFIX"
info "X11_PREFIX=$X11_PREFIX"
info "SRC_DIR=$SRC_DIR"
info "Log: $LOG"

# -------- Preflight checks --------
command -v git >/dev/null || fail "git not found"
[ -x "$BREW_PREFIX/bin/brew" ] || fail "Homebrew not found at $BREW_PREFIX"
[ -d "$X11_PREFIX/include" ] || fail "XQuartz headers not found at $X11_PREFIX (did 00_prereqs_mac.sh run?)"

# Required deps (via Homebrew/XQuartz)
need_pkgs=( tcl-tk cairo pkg-config )
for pkg in "${need_pkgs[@]}"; do
  if ! "$BREW_PREFIX/bin/brew" list --versions "$pkg" >/dev/null 2>&1; then
    info "Installing $pkg…"
    "$BREW_PREFIX/bin/brew" install "$pkg"
  fi
done
ok "Dependencies present"

# -------- Fetch source --------
cd "$SRC_DIR"
if [ ! -d magic ]; then
  info "Cloning Magic…"
  git clone "$MAGIC_REPO" magic
else
  info "Reusing existing magic src"
fi

cd magic
git fetch --all --tags
git checkout "$MAGIC_TAG"
git pull --ff-only || true

# Clean previous builds if prefix changed
[ -f Makefile ] && make distclean || true

# -------- Configure --------
CPPFLAGS="-I$BREW_PREFIX/include -I$X11_PREFIX/include"
LDFLAGS="-L$BREW_PREFIX/lib -L$X11_PREFIX/lib"
export CPPFLAGS LDFLAGS PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig"

# Notes:
# - We enable Cairo and disable OpenGL to avoid Mac OpenGL quirks on arm64.
# - We explicitly point to Tcl/Tk from Homebrew.
./configure \
  --prefix="$PREFIX" \
  --with-tcl="$BREW_PREFIX/opt/tcl-tk/lib" \
  --with-tk="$BREW_PREFIX/opt/tcl-tk/lib" \
  --with-x="$X11_PREFIX" \
  --enable-cairo \
  --disable-opengl

ok "Configured Magic"

# -------- Build & install --------
# The database header is auto-generated; to avoid rare parallel hazards, do a safe build.
info "Building Magic… (this can take a bit)"
make -j1           # header generation & early steps safely
make -j"$JOBS"

info "Installing Magic to $PREFIX"
make install

# Convenience wrapper
BIN="$PREFIX/bin/magic"
if [ -x "$BIN" ]; then
  ok "Magic installed: $BIN"
  touch "$STAMP_DIR/magic.ok"
else
  fail "Magic binary not found after install"
fi

# PATH hint
SHELL_RC="${SHELL_RC:-$HOME/.zshrc}"
if ! grep -q "$PREFIX/bin" "$SHELL_RC" 2>/dev/null; then
  info "Adding PATH hint to $SHELL_RC"
  {
    echo ""
    echo "# Added by 20_magic.sh"
    echo "export PATH=\"$PREFIX/bin:\$PATH\""
  } >> "$SHELL_RC"
fi

ok "Magic done."
