#!/usr/bin/env bash
# Magic (8.3) builder for macOS (Apple Silicon & Intel)
# - Installs under ~/.eda and updates ~/.eda/sky130/activate
# - Prefers MacPorts (/opt/local), falls back to Homebrew (/opt/homebrew)
# - Builds Tk/X11 GUI when XQuartz is present
# - Only uses the official Magic repo

set -Eeuo pipefail

# -------------------------
# Configurable environment (all with safe defaults)
# -------------------------
EDA_HOME="${EDA_HOME:-$HOME/.eda}"                 # base EDA dir (env lives here)
PREFIX="${PREFIX:-$EDA_HOME}"                      # install prefix
ACTIVATE_FILE="${ACTIVATE_FILE:-$EDA_HOME/sky130/activate}"
MAGIC_VER="${MAGIC_VER:-8.3.552}"                  # tag/branch in Magic repo
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
ENABLE_OPENGL="${ENABLE_OPENGL:-no}"               # yes/no
ENABLE_CAIRO="${ENABLE_CAIRO:-no}"                 # yes/no

# -------------------------
# Toolchain detection
# -------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "[ERR ] 'git' not found. Install Xcode CLT:  xcode-select --install" >&2
  exit 1
fi

TCL_PREFIX=""
TCLSH=""
if command -v port >/dev/null 2>&1 && [ -d /opt/local ]; then
  PKG_SYS="macports"
  TCL_PREFIX="/opt/local"
  TCL_BIN="$TCL_PREFIX/bin"
  TCLSH="$TCL_BIN/tclsh8.6"
elif command -v brew >/dev/null 2>&1; then
  PKG_SYS="homebrew"
  if brew --prefix tcl-tk >/dev/null 2>&1; then
    TCL_PREFIX="$(brew --prefix tcl-tk)"
  else
    TCL_PREFIX="/opt/homebrew/opt/tcl-tk"
  fi
  TCL_BIN="$TCL_PREFIX/bin"
  if [ -x "$TCL_BIN/tclsh8.6" ]; then
    TCLSH="$TCL_BIN/tclsh8.6"
  else
    TCLSH="$TCL_BIN/tclsh"
  fi
else
  echo "[ERR ] Neither MacPorts nor Homebrew found. Install one of them." >&2
  exit 1
fi

# XQuartz (X11) — optional but required for GUI
if [ -d /opt/X11 ]; then
  X11_PREFIX="/opt/X11"
  HAVE_X11=1
else
  X11_PREFIX=""
  HAVE_X11=0
fi

echo "[INFO] Using install PREFIX: $PREFIX"
echo "[INFO] Package system: $PKG_SYS"
echo "[INFO] TCL/TK prefix: $TCL_PREFIX"
echo "[INFO] Detected TCLSH: ${TCLSH:-"(none)"}"
if [ "$HAVE_X11" -eq 1 ]; then
  echo "[INFO] X11 detected at $X11_PREFIX (XQuartz). Magic will build with GUI."
else
  echo "[WARN] X11 (XQuartz) not found. Magic will build, but only '-dnull' (no GUI) will work."
fi

if [ ! -x "${TCLSH:-/nonexistent}" ]; then
  echo "[ERR ] tclsh not found/executable at $TCLSH" >&2
  echo "       Install Tcl/Tk 8.6 (MacPorts: 'sudo port install tcl tk' | Homebrew: 'brew install tcl-tk')." >&2
  exit 1
fi

# -------------------------
# Prepare dirs
# -------------------------
mkdir -p "$PREFIX"/{bin,lib,include,src} "$EDA_HOME/sky130"
BUILD_ROOT="$(mktemp -d -t magic-remote-build-XXXXXX)"
SRC_DIR="$BUILD_ROOT/magic-src"

cleanup() { [ -d "$BUILD_ROOT" ] && rm -rf "$BUILD_ROOT"; }
trap cleanup EXIT

# -------------------------
# Fetch + configure
# -------------------------
echo "[INFO] Cloning Magic ${MAGIC_VER}…"
git clone --depth 1 --branch "$MAGIC_VER" "$MAGIC_REPO" "$SRC_DIR" >/dev/null

cd "$SRC_DIR"

CFG=(
  "--prefix=$PREFIX"
  "--with-tcl=$TCL_PREFIX/lib"
  "--with-tk=$TCL_PREFIX/lib"
  "--with-tclinclude=$TCL_PREFIX/include"
)

if [ "$HAVE_X11" -eq 1 ]; then
  CFG+=("--x-includes=$X11_PREFIX/include" "--x-libraries=$X11_PREFIX/lib")
else
  CFG+=("--with-x=no")
fi

if [ "${ENABLE_OPENGL}" = "yes" ]; then CFG+=("--with-opengl"); else CFG+=("--with-opengl=no"); fi
if [ "${ENABLE_CAIRO}"  = "yes" ]; then CFG+=("--with-cairo");  else CFG+=("--with-cairo=no");  fi

export CC="${CC:-clang}"
export CFLAGS="${CFLAGS:-} -Wno-deprecated-non-prototype"

echo "[INFO] Running ./configure ${CFG[*]} …"
./configure "${CFG[@]}"

echo
echo "-----------------------------------------------------------"
echo "Configuration Summary (key bits):"
grep -E '^(X11|Python3|OpenGL|Cairo|Tcl/Tk):' config.log || true
echo "-----------------------------------------------------------"
echo

# -------------------------
# Build + install
# -------------------------
CORES="$(command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "[INFO] Building (make -j$CORES)…"
make -j"$CORES"

echo "[INFO] Installing (make install)…"
make install

# -------------------------
# Update environment file
# -------------------------
touch "$ACTIVATE_FILE"

append_once() {
  local line="$1"
  local file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

append_once '# magic (auto-added)' "$ACTIVATE_FILE"
append_once "export EDA_HOME=\"$EDA_HOME\"" "$ACTIVATE_FILE"
append_once "export PATH=\"$PREFIX/bin:\$PATH\"" "$ACTIVATE_FILE"
append_once "export MAGIC_HOME=\"$PREFIX\"" "$ACTIVATE_FILE"
[ "$HAVE_X11" -eq 1 ] && append_once 'export DISPLAY=${DISPLAY:-:0}' "$ACTIVATE_FILE"

echo
echo "[OK  ] Magic installed to: $PREFIX"
echo "[OK  ] Environment updated: $ACTIVATE_FILE"
cat <<'EOF'

Use it now:
  source ~/.eda/sky130/activate
  magic             # GUI, if XQuartz is running
# or headless:
  magic -dnull -noconsole

If you need XQuartz:
  open -a XQuartz
  xhost +localhost   # first time only
  source ~/.eda/sky130/activate
  DISPLAY=:0 magic &
EOF
