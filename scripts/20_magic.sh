#!/usr/bin/env bash
# Install MAGIC VLSI on macOS, linked to Tcl/Tk 8.6 (Aqua) and (optionally) launch the GUI.
# Usage:
#   bash scripts/20_magic.sh           # build/install only
#   bash scripts/20_magic.sh --gui     # build/install, then open GUI (Aqua)
#   RUN_GUI=1 bash scripts/20_magic.sh # same as --gui
set -euo pipefail

# ---------------- Config (overridable via env) ----------------
ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"

PREFIX="${PREFIX:-$HOME/.eda/sky130_dev}"        # isolated prefix
SRC_DIR="${SRC_DIR:-$HOME/src-eda}"
X11_PREFIX="${X11_PREFIX:-/opt/X11}"             # headers only; GUI uses Aqua
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
MAGIC_TAG="${MAGIC_TAG:-master}"                 # set a fixed tag if you want reproducibility
RUN_GUI="${RUN_GUI:-0}"                          # set to 1 or pass --gui to launch GUI after install

mkdir -p "$SRC_DIR" "$LOG_DIR" "$PREFIX"
LOG="$LOG_DIR/magic_install.log"
exec > >(tee -a "$LOG") 2>&1

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "[INFO] %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
fail(){ printf "❌ %s\n" "$*" >&2; exit 1; }
trap 'fail "Magic install failed at line $LINENO. See $LOG"' ERR

# ---------------- Args ----------------
if [[ "${1:-}" == "--gui" ]]; then RUN_GUI=1; fi

bold "Magic installer (Tk 8.6 / Aqua)"

# ---------------- Homebrew (robust) ----------------
BREW_BIN=""
for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x "$p" ]] && BREW_BIN="$p" && break
done
if [[ -z "$BREW_BIN" ]]; then
  info "Installing Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" ]] && BREW_BIN="$p" && break
  done
  [[ -n "$BREW_BIN" ]] || fail "Homebrew installed but not found on expected paths."
fi
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# ---------------- Deps (safe with set -u) ----------------
# Non-Tk deps
need_pkgs=(cairo pkg-config gawk make)
if ((${#need_pkgs[@]})); then
  for pkg in "${need_pkgs[@]}"; do
    if ! brew list --versions "$pkg" >/dev/null 2>&1; then
      info "Installing $pkg…"; brew install "$pkg"
    fi
  done
fi

# Tk 8.6 keg (Homebrew usually exposes 8.6 as tcl-tk@8; plain tcl-tk may be 9.x)
if ! brew list --versions tcl-tk@8 >/dev/null 2>&1 && ! brew list --versions tcl-tk >/dev/null 2>&1; then
  info "Installing Tcl/Tk 8.x…"
  brew install tcl-tk@8 || brew install tcl-tk
fi

# Resolve a prefix that is truly 8.6
TK86_PREFIX=""
for cand in "$(brew --prefix tcl-tk@8 2>/dev/null)" "$(brew --prefix tcl-tk 2>/dev/null)"; do
  [[ -n "$cand" ]] || continue
  if [[ -f "$cand/lib/tclConfig.sh" ]] && grep -q 'TCL_VERSION=8\.6' "$cand/lib/tclConfig.sh"; then
    TK86_PREFIX="$cand"; break
  fi
done
[[ -n "$TK86_PREFIX" ]] || fail "Could not find a Tcl/Tk **8.6** keg. Run: brew install tcl-tk@8"
info "Using Tcl/Tk 8.6 at: $TK86_PREFIX"

info "Prefix: $PREFIX"
info "Source: $SRC_DIR"
info "Jobs:   $JOBS"

# ---------------- Fetch/prepare Magic source ----------------
cd "$SRC_DIR"
if [[ ! -d magic ]]; then
  info "Cloning magic…"; git clone "$MAGIC_REPO" magic
fi
cd magic
git fetch --all --tags
git checkout "$MAGIC_TAG"
git pull --ff-only || true
make distclean >/dev/null 2>&1 || true

# ---------------- Configure (Aqua, Cairo on, OpenGL off) ----------------
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

# ---------------- Build & install ----------------
info "Building (header-safe stage)…"; make -j1
info "Building (parallel)…";         make -j"$JOBS"
info "Installing to $PREFIX";        make install

BIN="$PREFIX/bin/magic"
[[ -x "$BIN" ]] || fail "magic binary missing after install"
ok "Magic installed: $BIN"

# ---------------- Post-install: wish8.6 hint ----------------
ACTIVATE="$PREFIX/activate"
mkdir -p "$PREFIX"
if ! grep -q 'wish8\.6' "$ACTIVATE" 2>/dev/null; then
  {
    echo '# Prefer Tk 8.6 for Magic Aqua GUI'
    echo "export WISH=\"$TK86_PREFIX/bin/wish8.6\""
  } >> "$ACTIVATE"
  info "Added WISH hint to $ACTIVATE"
fi

# ---------------- Sanity (headless) ----------------
info "Headless sanity (Tcl/Tk + Magic version)…"
"$BIN" -d null -noconsole -rcfile /dev/null -T scmos <<'EOF'
puts "Tcl: [info patchlevel]  Tk: [tk patchlevel]"
puts "Magic: [magic::version]"
quit
EOF

# ---------------- Optional: launch GUI (Aqua) ----------------
if [[ "$RUN_GUI" == "1" ]]; then
  info "Launching Magic GUI (Aqua)…"
  # Kill any old wish/magic just in case
  pkill -if '(wish8\.6|magic)' 2>/dev/null || true
  # Run under wish8.6, force Tcl to prefer 8.6 libs, auto-open layout window
  exec env TCLLIBPATH="$TK86_PREFIX/lib" \
    "$TK86_PREFIX/bin/wish8.6" "$PREFIX/lib/magic/tcl/magic.tcl" \
    -d null -T scmos -rcfile /dev/null -wrapper
fi

cat <<EOS

==============================================================
Magic build complete (linked to Tcl/Tk 8.6).

GUI (Aqua) quick start (no XQuartz needed):
  \${WISH:-$TK86_PREFIX/bin/wish8.6} "$PREFIX/lib/magic/tcl/magic.tcl" \\
      -d null -T scmos -rcfile /dev/null -wrapper

Or just:
  RUN_GUI=1 bash scripts/20_magic.sh
  # (same as: bash scripts/20_magic.sh --gui)

Log: $LOG
==============================================================
EOS

ok "Magic done."
