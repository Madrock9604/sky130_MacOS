#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# scripts/20_magic.sh
# -----------------------------------------------------------------------------
# Purpose:
#   Install MAGIC VLSI from source on macOS into ~/.eda/sky130_dev,
#   pinned to Tcl/Tk 8.6 (Aqua). No manual steps required.
#
# What this script does:
#   - Ensures Homebrew is installed and available in THIS shell.
#   - Ensures/installs build tools (git, cairo, pkg-config, gawk, make, wget).
#   - Ensures/installs Tcl/Tk 8.6 (Homebrew’s "tcl-tk@8") and verifies it.
#   - Downloads/builds/installs Magic with Cairo enabled and OpenGL disabled.
#   - Adds WISH=…/wish8.6 to ~/.eda/sky130_dev/activate for easy GUI launching.
#   - (Optional) Launches Magic GUI immediately with --gui or RUN_GUI=1.
#
# Usage:
#   bash scripts/20_magic.sh           # build/install only
#   bash scripts/20_magic.sh --gui     # build/install, then open GUI
#   RUN_GUI=1 bash scripts/20_magic.sh # same as --gui
#
# Logs:
#   ~/sky130-diag/magic_install.log
#
# After install (open GUI any time):
#   magic -d null -T scmos -rcfile /dev/null -wrapper
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------------- Configuration (change only if you know why) ----------------
ARCH="$(uname -m)"
DEFAULT_BREW_PREFIX="/opt/homebrew"; [ "$ARCH" != "arm64" ] && DEFAULT_BREW_PREFIX="/usr/local"

PREFIX="${PREFIX:-$HOME/.eda/sky130_dev}"     # Install location
SRC_DIR="${SRC_DIR:-$HOME/src-eda}"           # Where sources are cloned/built
X11_PREFIX="${X11_PREFIX:-/opt/X11}"          # Headers path; GUI uses Aqua (not X11)
LOG_DIR="${LOG_DIR:-$HOME/sky130-diag}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
MAGIC_TAG="${MAGIC_TAG:-master}"              # For reproducibility you may pin a tag
RUN_GUI="${RUN_GUI:-0}"                        # Set to "1" or pass --gui to open the GUI after build

mkdir -p "$SRC_DIR" "$LOG_DIR" "$PREFIX"
LOG="$LOG_DIR/magic_install.log"
exec > >(tee -a "$LOG") 2>&1

# ---------------- Helpers ----------------
say()   { printf "[INFO] %s\n" "$*"; }
ok()    { printf "✅ %s\n" "$*"; }
die()   { printf "❌ %s\n" "$*\n" >&2; exit 1; }
trap 'die "Magic install failed at line $LINENO. See log: $LOG"' ERR

# Accept --gui flag
if [[ "${1:-}" == "--gui" ]]; then RUN_GUI=1; fi

say "Magic installer (Tk 8.6 / Aqua)"

# ---------------- Ensure Homebrew is present and usable ----------------
BREW_BIN=""
for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x "$p" ]] && BREW_BIN="$p" && break
done
if [[ -z "$BREW_BIN" ]]; then
  say "Installing Homebrew… (follow prompts if shown)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  for p in "$DEFAULT_BREW_PREFIX/bin/brew" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" ]] && BREW_BIN="$p" && break
  done
  [[ -n "$BREW_BIN" ]] || die "Homebrew installed but not found on expected paths."
fi
# Load brew environment into THIS shell
eval "$("$BREW_BIN" shellenv)"
ok "Homebrew ready: $BREW_BIN"

# ---------------- Install required packages ----------------
# Build tools (idempotent: skipped if already installed)
NEEDED=(git cairo pkg-config gawk make wget)
for pkg in "${NEEDED[@]}"; do
  if ! brew list --versions "$pkg" >/dev/null 2>&1; then
    say "Installing $pkg…"
    brew install "$pkg"
  fi
done
ok "Common build dependencies installed"

# ---------------- Ensure Tcl/Tk 8.6 exists and find its prefix ----------------
brew update >/dev/null

# Install Homebrew’s Tk 8.x keg (this is 8.6); harmless if already installed
brew list --versions tcl-tk@8 >/dev/null 2>&1 || brew install tcl-tk@8 || true

find_tk86_prefix() {
  # Different Homebrew layouts: tclConfig.sh may live in lib/ or lib/tcl8.6/
  for cand in "$(brew --prefix tcl-tk@8 2>/dev/null)" "$(brew --prefix tcl-tk 2>/dev/null)"; do
    [[ -n "$cand" ]] || continue
    for cfg in "$cand/lib/tclConfig.sh" "$cand/lib/tcl8.6/tclConfig.sh"; do
      if [[ -f "$cfg" ]] && grep -q 'TCL_VERSION=8\.6' "$cfg"; then
        echo "$cand"; return 0
      fi
    done
  done
  return 1
}

TK86_PREFIX="$(find_tk86_prefix || true)"
if [[ -z "$TK86_PREFIX" ]]; then
  say "Reinstalling tcl-tk@8 to ensure 8.6 symbols…"
  brew reinstall tcl-tk@8 || true
  TK86_PREFIX="$(find_tk86_prefix || true)"
fi
[[ -n "$TK86_PREFIX" ]] || die "Tcl/Tk 8.6 keg not found after install. See $LOG"
[[ -x "$TK86_PREFIX/bin/wish8.6" ]] || die "wish8.6 not found under $TK86_PREFIX"
ok "Tk 8.6 at: $TK86_PREFIX"

# ---------------- Fetch Magic source ----------------
cd "$SRC_DIR"
if [[ ! -d magic ]]; then
  say "Cloning Magic…"
  git clone "$MAGIC_REPO" magic
fi
cd magic
git fetch --all --tags
git checkout "$MAGIC_TAG"
git pull --ff-only || true
make distclean >/dev/null 2>&1 || true

# ---------------- Configure Magic (Aqua/Tk 8.6, Cairo ON, OpenGL OFF) ----------------
# We include X11 headers in case some optional bits look for them; GUI uses Aqua via Tk.
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig"
export CPPFLAGS="-I$(brew --prefix)/include -I$X11_PREFIX/include -I$TK86_PREFIX/include"
export LDFLAGS="-L$(brew --prefix)/lib -L$X11_PREFIX/lib -L$TK86_PREFIX/lib"

say "Configuring Magic…"
./configure \
  --prefix="$PREFIX" \
  --with-tcl="$TK86_PREFIX/lib" \
  --with-tk="$TK86_PREFIX/lib" \
  --with-x="$X11_PREFIX" \
  --enable-cairo \
  --disable-opengl
ok "Configure OK"

# ---------------- Build and install ----------------
say "Building (header-safe stage)…"
make -j1
say "Building (parallel)…"
make -j"$JOBS"
say "Installing to $PREFIX…"
make install

BIN="$PREFIX/bin/magic"
[[ -x "$BIN" ]] || die "Magic binary missing after install."
ok "Magic installed: $BIN"

# ---------------- Post-install: teach your environment about wish8.6 ----------------
ACTIVATE="$PREFIX/activate"
mkdir -p "$PREFIX"
if ! grep -q 'wish8\.6' "$ACTIVATE" 2>/dev/null; then
  {
    echo '# Prefer Tk 8.6 for Magic Aqua GUI'
    echo "export WISH=\"$TK86_PREFIX/bin/wish8.6\""
  } >> "$ACTIVATE"
  say "Added WISH hint to $ACTIVATE"
fi

# ---------------- Sanity check (headless; confirms Tcl/Tk 8.6 is used) ----------------
say "Headless sanity check (Tcl/Tk + Magic versions)…"
"$BIN" -d null -noconsole -rcfile /dev/null -T scmos <<'EOF'
puts "Tcl: [info patchlevel]  Tk: [tk patchlevel]"
puts "Magic: [magic::version]"
quit
EOF

# ---------------- Optional: open the GUI right now ----------------
if [[ "$RUN_GUI" == "1" ]]; then
  say "Launching Magic GUI (Aqua)…"
  # Clean any previous wish/magic processes just in case
  pkill -if '(wish8\.6|magic)' 2>/dev/null || true
  # Run Magic under wish8.6 and auto-open a layout window (no XQuartz needed)
  exec env TCLLIBPATH="$TK86_PREFIX/lib" \
    "$TK86_PREFIX/bin/wish8.6" "$PREFIX/lib/magic/tcl/magic.tcl" \
    -d null -T scmos -rcfile /dev/null -wrapper
fi

ok "Magic build complete. To open GUI later:"
echo "  magic -d null -T scmos -rcfile /dev/null -wrapper"
echo "Log: $LOG"
