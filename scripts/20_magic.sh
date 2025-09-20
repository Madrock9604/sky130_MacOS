#!/usr/bin/env bash
# Install MAGIC VLSI from source on macOS (Apple Silicon or Intel)
# Safe for side-by-side with an existing student install.
# Usage: bash scripts/20_magic.sh

set -euo pipefail

# ---------- Config (override via env before running) ----------
ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"
[ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"

PREFIX="${PREFIX:-$HOME/.eda/sky130_dev}"          # isolated from any existing setup
BREW_PREFIX="${BREW_PREFIX:-$DEFAULT_BREW_PREFIX}"
X11_PREFIX="${X11_PREFIX:-/opt/X11}"               # XQuartz
SRC_DIR="${SRC_DIR:-$HOME/src-eda}"
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
# Pin if you want reproducible builds, e.g. 8.3.500. Otherwise 'master'.
MAGIC_TAG="${MAGIC_TAG:-master}"

# Feature flags
ENABLE_CAIRO="${ENABLE_CAIRO:-1}"
ENABLE_OPENGL="${ENABLE_OPENGL:-0}"  # OpenGL on macOS often causes pain; default off.

# ---------- Internals ----------
mkdir -p "$SRC_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/magic_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }

trap 'fail "Magic install failed (line $LINENO). See $LOG_FILE"' ERR

bold "Magic build"
info "PREFIX        = $PREFIX"
info "BREW_PREFIX   = $BREW_PREFIX"
info "X11_PREFIX    = $X11_PREFIX"
info "SRC_DIR       = $SRC_DIR"
info "MAGIC_TAG     = $MAGIC_TAG"
info "JOBS          = $JOBS"

# ---------- Preflight ----------
command -v git >/dev/null || fail "git not found"
[ -x "$BREW_PREFIX/bin/brew" ] || fail "Homebrew not found at $BREW_PREFIX (run 00_prereqs_mac.sh)"
[ -d "$X11_PREFIX/include" ] || fail "XQuartz headers not found at $X11_PREFIX (run 00_prereqs_mac.sh)"

# Required deps
DEPS=( tcl-tk cairo pkg-config )
for pkg in "${DEPS[@]}"; do
  if ! "$BREW_PREFIX/bin/brew" list --versions "$pkg" >/dev/null 2>&1; then
    info "Installing $pkg…"
    "$BREW_PREFIX/bin/brew" install "$pkg"
  fi
done
ok "Dependencies present"

# ---------- Fetch source ----------
cd "$SRC_DIR"
if [ ! -d magic ]; then
  info "Cloning magic…"
  git clone "$MAGIC_REPO" magic
else
  info "Using existing magic source"
fi

cd magic
git fetch --all --tags
git checkout "$MAGIC_TAG"
# If tag is branch-like, update; otherwise it’s a fixed tag and pull will no-op
git pull --ff-only || true

# Clean if previously configured differently
make distclean >/dev/null 2>&1 || true

# ---------- Configure ----------
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig"
export CPPFLAGS="-I$BREW_PREFIX/include -I$X11_PREFIX/include"
export LDFLAGS="-L$BREW_PREFIX/lib -L$X11_PREFIX/lib"

conf_flags=(
  "--prefix=$PREFIX"
  "--with-tcl=$BREW_PREFIX/opt/tcl-tk/lib"
  "--with-tk=$BREW_PREFIX/opt/tcl-tk/lib"
  "--with-x=$X11_PREFIX"
)

# graphics backends
if [ "$ENABLE_CAIRO" = "1" ]; then conf_flags+=( "--enable-cairo" ); else conf_flags+=( "--disable-cairo" ); fi
if [ "$ENABLE_OPENGL" = "1" ]; then conf_flags+=( "--enable-opengl" ); else conf_flags+=( "--disable-opengl" ); fi

info "Configuring magic…"
./configure "${conf_flags[@]}"

ok "Configure OK"

# ---------- Build (avoid header race) ----------
# database/database.h is generated; do first steps single-threaded to avoid rare race.
info "Building magic (stage 1)…"
make -j1
info "Building magic (stage 2)…"
make -j"$JOBS"

# ---------- Install ----------
info "Installing to $PREFIX"
make install

BIN="$PREFIX/bin/magic"
[ -x "$BIN" ] || fail "magic binary missing after install"

# Add PATH hint if not present
SHELL_RC="${SHELL_RC:-$HOME/.zshrc}"
if ! grep -q "$PREFIX/bin" "$SHELL_RC" 2>/dev/null; then
  info "Adding PATH to $SHELL_RC"
  {
    echo ""
    echo "# Added by 20_magic.sh"
    echo "export PATH=\"$PREFIX/bin:\$PATH\""
  } >> "$SHELL_RC"
fi

ok "Magic installed: $BIN"
echo
echo "Next:"
echo "  1) Open a NEW terminal so PATH updates."
echo "  2) Test X connection:"
echo "       magic -d XR -noconsole &"
echo "     (XQuartz should appear; close with ':q' in magic)"
