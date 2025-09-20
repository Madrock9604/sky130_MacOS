#!/usr/bin/env bash
#
# build-magic-macos.sh
# One-file macOS builder for Magic (Aqua/Cocoa GUI, no X11).
#
# - Requires: macOS + Homebrew
# - Installs Homebrew deps if missing (tcl-tk, etc.)
# - Configures Magic to use Brew Tcl/Tk and Aqua (no X11) to avoid colormap/X11 crashes.
# - Installs under $PREFIX (default: $HOME/eda)
#
# Usage:
#   ./build-magic-macos.sh                # default build (prefix=$HOME/eda, branch=8.3)
#   PREFIX=/opt/eda ./build-magic-macos.sh
#   MAGIC_BRANCH=master ./build-magic-macos.sh
#
set -euo pipefail

### ---------- Config ----------
: "${PREFIX:="$HOME/eda"}"
: "${SRCROOT:="$HOME/src"}"
: "${MAGIC_REPO:="https://github.com/RTimothyEdwards/magic.git"}"
: "${MAGIC_BRANCH:="8.3"}"     # try "master" if you want bleeding edge
: "${JOBS:="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"}"

### ---------- Helpers ----------
log() { printf '\n\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[ERR]\033[0m %s\n' "$*"; exit 1; }

### ---------- OS / Brew checks ----------
if [[ "$(uname -s)" != "Darwin" ]]; then
  die "This script is macOS-only."
fi

if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew not found. Install from https://brew.sh and re-run."
fi

### ---------- Install deps ----------
log "Ensuring required Homebrew packages are installed…"
# tcl-tk provides wish/tclsh headers/libs (Aqua). Others are common build tools.
brew list --versions tcl-tk >/dev/null 2>&1 || brew install tcl-tk
brew list --versions pkg-config >/dev/null 2>&1 || brew install pkg-config
brew list --versions autoconf  >/dev/null 2>&1 || brew install autoconf
brew list --versions automake  >/dev/null 2>&1 || brew install automake
brew list --versions libtool   >/dev/null 2>&1 || brew install libtool
brew list --versions cairo     >/dev/null 2>&1 || brew install cairo
brew list --versions git       >/dev/null 2>&1 || brew install git

BREW_PREFIX="$(brew --prefix)"
TCL_PREFIX="$(brew --prefix tcl-tk)"   # keg: …/opt/tcl-tk

# Put brew Tcl/Tk tools first so we pick up Aqua wish/tclsh.
export PATH="$TCL_PREFIX/bin:$PATH"

# Headers/libs live in multiple dirs depending on Tcl/Tk version (8.6 vs 9.x).
CPP_DIRS=()
for d in "$TCL_PREFIX/include" "$TCL_PREFIX/include/tcl8.6" "$TCL_PREFIX/include/tcl8.7" "$TCL_PREFIX/include/tcl9.0"; do
  [[ -d "$d" ]] && CPP_DIRS+=("-I$d")
done
LDPATHS=()
for d in "$TCL_PREFIX/lib"; do
  [[ -d "$d" ]] && LDPATHS+=("-L$d")
done

# Cairo pkgconfig lives in brew prefix; Tcl’s .pc files live under the keg.
export PKG_CONFIG_PATH="$TCL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="${CPPFLAGS:-} ${CPP_DIRS[*]}"
export LDFLAGS="${LDFLAGS:-} ${LDPATHS[*]}"

# Locate tclsh/wish from Brew keg
TCLSH="$(command -v tclsh || true)"
WISH="$(command -v wish || true)"
[[ -x "$TCLSH" ]] || die "tclsh not found in PATH ($PATH)"
[[ -x "$WISH"  ]] || die "wish not found in PATH ($PATH)"

log "Using Tcl/Tk from: $TCL_PREFIX"
log "tclsh: $TCLSH"
log "wish : $WISH"
log "CPPFLAGS: $CPPFLAGS"
log "LDFLAGS : $LDFLAGS"
log "PKG_CONFIG_PATH: ${PKG_CONFIG_PATH:-<empty>}"

### ---------- Prepare dirs ----------
mkdir -p "$SRCROOT" "$PREFIX"
log "Source root: $SRCROOT"
log "Install prefix: $PREFIX"

### ---------- Fetch Magic ----------
cd "$SRCROOT"
if [[ -d magic/.git ]]; then
  log "Found existing magic repo, fetching updates…"
  git -C magic fetch --all --tags --prune
else
  log "Cloning magic repo…"
  git clone "$MAGIC_REPO" magic
fi

cd magic
# Try branch/tag; fall back gracefully if not present.
if git rev-parse --verify --quiet "$MAGIC_BRANCH" >/dev/null; then
  git checkout "$MAGIC_BRANCH"
else
  warn "Branch/tag '$MAGIC_BRANCH' not found; staying on current."
fi
git submodule update --init --recursive

### ---------- Autoconf (if needed) ----------
if [[ ! -x ./configure ]]; then
  log "Generating configure (autogen)…"
  ./configure || true # some trees generate on failure path
fi

if [[ ! -x ./configure ]]; then
  log "Running 'autoreconf -fi' to generate configure…"
  autoreconf -fi
fi

[[ -x ./configure ]] || die "configure script not found after autoreconf."

### ---------- Configure ----------
# Key bits:
#  - --with-x=no    => use Aqua (Cocoa) Tk; avoids X11 colormap crashes (your segfaults).
#  - --with-tcl/--with-tk: point to Brew Tcl/Tk libs
#  - --with-tclsh/--with-wish: make sure it binds to the Aqua binaries
#
CONFIG_ARGS=(
  "--prefix=$PREFIX"
  "--with-x=no"
  "--with-tcl=$TCL_PREFIX/lib"
  "--with-tk=$TCL_PREFIX/lib"
  "--with-tclsh=$TCLSH"
  "--with-wish=$WISH"
)

log "Configuring Magic with: ${CONFIG_ARGS[*]}"
./configure "${CONFIG_ARGS[@]}"

### ---------- Build & Install ----------
log "Building (make -j$JOBS)…"
make -j"$JOBS"

log "Installing to $PREFIX…"
make install

### ---------- Smoke tests ----------
MAGIC_BIN="$PREFIX/bin/magic"
[[ -x "$MAGIC_BIN" ]] || die "Magic binary not found at $MAGIC_BIN"

log "Headless sanity check…"
# Use the built magic directly (ensures rpaths/paths are good).
"$MAGIC_BIN" -dnull -noconsole -nowindow -rcfile /dev/null -T minimum <<<'quit' >/dev/null 2>&1 \
  && log "[OK] magic headless" \
  || die "Headless check failed."

cat <<'EOF'

--------------------------------------------
Magic (Aqua) installed successfully 🎉
--------------------------------------------

To use it in your shell sessions, add to your shell rc (e.g., ~/.zshrc):

  export PATH="$HOME/eda/bin:$PATH"

(If you used a custom PREFIX, substitute it.)

Launch the GUI:

  magic

If 'magic' still segfaults, it usually means something forced it back onto X11.
This build is linked to Aqua Tk, so ensure you are NOT setting DISPLAY or X11 vars.
You can verify the binary path with:

  which magic
  otool -L "$(which magic)" | grep -E 'tcl|tk'

You should see it pulling from Homebrew’s tcl-tk keg (…/opt/tcl-tk).

EOF
