#!/usr/bin/env bash
# Build/install Magic on macOS pinned to Tcl/Tk 8.6 (Aqua). Optional GUI launch.
# Usage:
#   bash scripts/20_magic.sh           # build/install only
#   bash scripts/20_magic.sh --gui     # build/install then open GUI
#   RUN_GUI=1 bash scripts/20_magic.sh # same as --gui
set -euo pipefail

# ---- Config ----
ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"
PREFIX="${PREFIX:-$HOME/.eda/sky130_dev}"
SRC_DIR="${SRC_DIR:-$HOME/src-eda}"
X11_PREFIX="${X11_PREFIX:-/opt/X11}"   # headers; GUI uses Aqua
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
MAGIC_TAG="${MAGIC_TAG:-master}"
RUN_GUI="${RUN_GUI:-0}"                # or pass --gui
TK86_PREFIX="${TK86_PREFIX:-}"         # allow override if needed

mkdir -p "$SRC_DIR" "$LOG_DIR" "$PREFIX"
LOG="$LOG_DIR/magic_install.log"
exec > >(tee -a "$LOG") 2>&1

info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }

# args
[ "${1:-}" = "--gui" ] && RUN_GUI=1

echo "Magic installer (Tk 8.6 / Aqua)"

# ---- Ensure Homebrew (and brew env in THIS shell) ----
BREW_BIN=""
for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$p" ] && BREW_BIN="$p" && break
done
if [ -z "$BREW_BIN" ]; then
  echo "[INFO] Running prereqs to install Homebrew…"
  bash "$(dirname "$0")/00_prereqs_mac.sh"
  for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$p" ] && BREW_BIN="$p" && break
  done
fi
[ -n "$BREW_BIN" ] || fail "Homebrew not found even after prereqs."
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# ---- Make sure Tk 8.6 exists (use prereqs script if needed) ----
if [ -z "$TK86_PREFIX" ]; then
  for cand in "$(brew --prefix tcl-tk@8 2>/dev/null)" "$(brew --prefix tcl-tk 2>/dev/null)"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/lib/tclConfig.sh" ] && grep -q 'TCL_VERSION=8\.6' "$cand/lib/tclConfig.sh"; then
      TK86_PREFIX="$cand"; break
    fi
  done
fi
if [ -z "$TK86_PREFIX" ]; then
  echo "[INFO] Ensuring Tk 8.6 via prereqs…"
  bash "$(dirname "$0")/00_prereqs_mac.sh"
  for cand in "$(brew --prefix tcl-tk@8 2>/dev/null)" "$(brew --prefix tcl-tk 2>/dev/null)"; do
    [ -n "$cand" ] || continue
    if [ -f "$cand/lib/tclConfig.sh" ] && grep -q 'TCL_VERSION=8\.6' "$cand/lib/tclConfig.sh"; then
      TK86_PREFIX="$cand"; break
    fi
  done
fi
[ -n "$TK86_PREFIX" ] || fail "Tcl/Tk 8.6 keg not found. (Repo path tried prereqs)."
ok "Using Tk 8.6 at: $TK86_PREFIX"

# ---- Non-Tk deps (safe with set -u) ----
need_pkgs=(cairo pkg-config gawk make)
if ((${#need_pkgs[@]})); then
  for pkg in "${need_pkgs[@]}"; do
    brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"
  done
fi

# ---- Fetch / prepare Magic ----
cd "$SRC_DIR"
[ -d magic ] || { info "Cloning magic…"; git clone "$MAGIC_REPO" magic; }
cd magic
git fetch --all --tags
git checkout "$MAGIC_TAG"
git pull --ff-only || true
make distclean >/dev/null 2>&1 || true

# ---- Configure (Aqua, Cairo ON, OpenGL OFF) ----
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

# ---- Build & install ----
info "Building (header-safe)…"; make -j1
info "Building (parallel)…";   make -j"$(sysctl -n hw.ncpu)"
info "Installing to $PREFIX";  make install

BIN="$PREFIX/bin/magic"
[ -x "$BIN" ] || fail "magic binary missing after install"
ok "Magic installed: $BIN"

# ---- Add wish8.6 hint to activate ----
ACT="$PREFIX/activate"
mkdir -p "$PREFIX"
grep -q 'wish8\.6' "$ACT" 2>/dev/null || {
  {
    echo '# Prefer Tk 8.6 for Magic Aqua GUI'
    echo "export WISH=\"$TK86_PREFIX/bin/wish8.6\""
  } >> "$ACT"
}

# ---- Headless sanity ----
info "Headless sanity (Tcl/Tk + Magic)…"
"$BIN" -d null -noconsole -rcfile /dev/null -T scmos <<'EOF'
puts "Tcl: [info patchlevel]  Tk: [tk patchlevel]"
puts "Magic: [magic::version]"
quit
EOF

# ---- Optional GUI launch ----
if [ "$RUN_GUI" = "1" ]; then
  info "Launching GUI (Aqua)…"
  pkill -if '(wish8\.6|magic)' 2>/dev/null || true
  exec env TCLLIBPATH="$TK86_PREFIX/lib" \
    "$TK86_PREFIX/bin/wish8.6" "$PREFIX/lib/magic/tcl/magic.tcl" \
    -d null -T scmos -rcfile /dev/null -wrapper
fi

ok "Magic done. To open GUI:  magic -d null -T scmos -rcfile /dev/null -wrapper"
