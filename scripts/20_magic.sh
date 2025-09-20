#!/usr/bin/env bash
# Install MAGIC VLSI from source on macOS, linked to Tcl/Tk 8.6 (Aqua).
# Safe for side-by-side with any existing student install.
# Usage: bash scripts/20_magic.sh

set -euo pipefail

# ---------- Config (override via env before running) ----------
ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"

PREFIX="${PREFIX:-$HOME/.eda/sky130_dev}"        # isolated prefix (won't touch student setup)
SRC_DIR="${SRC_DIR:-$HOME/src-eda}"
X11_PREFIX="${X11_PREFIX:-/opt/X11}"             # headers present even if we use Aqua
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
MAGIC_TAG="${MAGIC_TAG:-master}"                 # set a specific tag for reproducibility if desired

mkdir -p "$SRC_DIR" "$LOG_DIR" "$PREFIX"
LOG="$LOG_DIR/magic_install.log"
exec > >(tee -a "$LOG") 2>&1

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }
trap 'fail "Magic install failed at line $LINENO. See $LOG"' ERR

bold "Magic installer (Tk 8.6 / Aqua)"

# ---------- Ensure Homebrew is available in THIS shell ----------
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
  [ -n "$BREW_BIN" ] || fail "Homebrew installed but not found on expected paths."
fi
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# ---------- Deps (idempotent) ----------
# NOTE: We need Tk 8.6 to avoid Tk 9 GUI breakage with openwrapper.

# Install non-Tk deps first (guarded for set -u)
need_pkgs=( cairo pkg-config gawk make )
set +u
for pkg in "${need_pkgs[@]}"; do
  if ! brew list --versions "$pkg" >/dev/null 2>&1; then
    info "Installing $pkg…"
    brew install "$pkg"
  fi
done
set -u

# Install a Tk 8.6 keg (some brews name it @8)
if brew list --versions tcl-tk@8 >/dev/null 2>&1; then
  : # already have @8
elif brew list --versions tcl-tk >/dev/null 2>&1; then
  : # plain tcl-tk may be 8.6 on some setups
else
  info "Installing Tcl/Tk 8.x…"
  brew install tcl-tk@8 || brew install tcl-tk
fi

# Resolve a prefix that is truly 8.6
TK86_PREFIX=""
for cand in \
  "$(brew --prefix tcl-tk@8 2>/dev/null)" \
  "$(brew --prefix tcl-tk 2>/dev/null)"
do
  [ -n "$cand" ] || continue
  if [ -f "$cand/lib/tclConfig.sh" ] && grep -q 'TCL_VERSION=8\.6' "$cand/lib/tclConfig.sh"; then
    TK86_PREFIX="$cand"
    break
  fi
done

[ -n "${TK86_PREFIX:-}" ] || fail "Could not find a Tcl/Tk **8.6** keg via Homebrew. Try: brew reinstall tcl-tk@8"
info "Using Tcl/Tk 8.6 at: $TK86_PREFIX"


# ---------- Resolve Tcl/Tk 8.6 keg ----------
TK86_PREFIX="$(brew --prefix tcl-tk@8.6 2>/dev/null || brew --prefix tcl-tk@8 2>/dev/null || true)"
[ -n "$TK86_PREFIX" ] && [ -f "$TK86_PREFIX/lib/tclConfig.sh" ] || fail "Tcl/Tk 8.6 prefix not found."

info "Using Tcl/Tk 8.6 at: $TK86_PREFIX"
info "Prefix: $PREFIX"
info "Source: $SRC_DIR"
info "Jobs:   $JOBS"

# ---------- Fetch/prepare Magic source ----------
cd "$SRC_DIR"
if [ ! -d magic ]; then
  info "Cloning magic…"
  git clone "$MAGIC_REPO" magic
fi
cd magic
git fetch --all --tags
git checkout "$MAGIC_TAG"
git pull --ff-only || true
make distclean >/dev/null 2>&1 || true

# ---------- Configure to Tk 8.6 (Aqua), Cairo ON, OpenGL OFF ----------
# We still include X11 headers; but GUI will use Tk/Aqua (-d null + openwrapper/-wrapper).
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"
export CPPFLAGS="-I$(brew --prefix)/include -I$X11_PREFIX/include -I$TK86_PREFIX/include"
export LDFLAGS="-L$(brew --prefix)/lib -L$X11_PREFIX/lib -L$TK86_PREFIX/lib"

info "Configuring magic…"
./configure \
  --prefix="$PREFIX" \
  --with-tcl="$TK86_PREFIX/lib" \
  --with-tk="$TK86_PREFIX/lib" \
  --with-x="$X11_PREFIX" \
  --enable-cairo \
  --disable-opengl

ok "Configure OK"

# ---------- Build & install (avoid header race) ----------
info "Building (header-safe stage)…"
make -j1
info "Building (parallel)…"
make -j"$JOBS"

info "Installing to $PREFIX"
make install

# ---------- Post-install: path hint + Aqua launcher hint ----------
BIN="$PREFIX/bin/magic"
[ -x "$BIN" ] || fail "magic binary missing after install"
ok "Magic installed: $BIN"

# Append wish8.6 hint to activate (used by GUI/Aqua launchers)
ACTIVATE="$PREFIX/activate"
mkdir -p "$PREFIX"
if ! grep -q 'wish8\.6' "$ACTIVATE" 2>/dev/null; then
  {
    echo '# Prefer Tk 8.6 for Magic Aqua GUI'
    echo "export WISH=\"$TK86_PREFIX/bin/wish8.6\""
  } >> "$ACTIVATE"
  info "Added WISH hint to $ACTIVATE"
fi

# ---------- Sanity check ----------
info "Headless sanity (Tcl/Tk + Magic version)…"
"$BIN" -d null -noconsole -rcfile /dev/null -T scmos <<'EOF'
puts "Tcl: [info patchlevel]  Tk: [tk patchlevel]"
puts "Magic: [magic::version]"
quit
EOF

cat <<EOS

==============================================================
Magic build complete (linked to Tcl/Tk 8.6).

GUI (Aqua) quick start (no XQuartz needed):
  \${WISH:-$TK86_PREFIX/bin/wish8.6} "$PREFIX/lib/magic/tcl/magic.tcl" \\
      -d null -T scmos -rcfile /dev/null -wrapper

Or, if your shell sources $PREFIX/activate (recommended via 05_env_activate.sh):
  magic -d null -T scmos -rcfile /dev/null -wrapper

Logs: $LOG
==============================================================
EOS

ok "Magic done."
