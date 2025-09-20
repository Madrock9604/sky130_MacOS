#!/usr/bin/env bash
set -euo pipefail

# ===== Config (can be overridden via env) =====
: "${PREFIX:="$HOME/.eda"}"
: "${ENVROOT:="$HOME/.eda/sky130"}"
: "${X11_TCLTK_PREFIX:="$HOME/.eda/x11-tcltk"}"
: "${TCL_VER:="8.6.13"}"
: "${TK_VER:="8.6.13"}"
: "${MAGIC_VER:="8.3.552"}"
: "${MAGIC_URL:="https://github.com/RTimothyEdwards/magic/archive/refs/tags/${MAGIC_VER}.tar.gz"}"

BIN_DIR="$ENVROOT/bin"
ACTIVATE="$ENVROOT/activate"

mkdir -p "$BIN_DIR"
mkdir -p "$PREFIX/src"
WORKDIR="$(mktemp -d /tmp/magic-x11.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERR ] %s\n' "$*" >&2; exit 1; }

# ===== Homebrew + deps =====
ensure_brew() {
  if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv || true)"
    eval "$(/usr/local/bin/brew shellenv || true)"
  fi
  # shellcheck disable=SC2046
  eval "$($(command -v brew) shellenv)"
}

brew_deps() {
  log "Installing brew deps (OK if already present)…"
  brew install pkg-config wget coreutils libx11 cairo libglu freeglut || true
  brew install --cask xquartz || true
}

# ===== Build Tcl/Tk (X11) locally (no sudo) =====
build_tcl() {
  log "Building Tcl ${TCL_VER} (X11-agnostic core)…"
  cd "$WORKDIR"
  local TARBALL="tcl${TCL_VER}-src.tar.gz"
  local URL="https://prdownloads.sourceforge.net/tcl/${TARBALL}"
  curl -fsSL "$URL" -o "$TARBALL"
  tar xfz "$TARBALL"
  cd "tcl${TCL_VER}/unix"
  ./configure --prefix="$X11_TCLTK_PREFIX"
  make -j"$(sysctl -n hw.ncpu || echo 4)"
  make install
}

build_tk() {
  log "Building Tk ${TK_VER} (with X11)…"
  cd "$WORKDIR"
  local TARBALL="tk${TK_VER}-src.tar.gz"
  local URL="https://prdownloads.sourceforge.net/tcl/${TARBALL}"
  curl -fsSL "$URL" -o "$TARBALL"
  tar xfz "$TARBALL"
  cd "tk${TK_VER}/unix"

  # Determine brew/XQuartz prefixes
  local BREW_PREFIX; BREW_PREFIX="$(brew --prefix)"
  local XQ_PREFIX="/opt/X11"

  ./configure \
    --prefix="$X11_TCLTK_PREFIX" \
    --with-tcl="$X11_TCLTK_PREFIX/lib" \
    --with-x \
    --x-includes="${XQ_PREFIX}/include" \
    --x-libraries="${XQ_PREFIX}/lib"
  make -j"$(sysctl -n hw.ncpu || echo 4)"
  make install
}

# ===== Build Magic against our X11 Tcl/Tk =====
build_magic() {
  log "Fetching Magic ${MAGIC_VER}…"
  cd "$WORKDIR"
  curl -fsSL "$MAGIC_URL" -o "magic-${MAGIC_VER}.tar.gz"
  tar xfz "magic-${MAGIC_VER}.tar.gz"
  cd "magic-${MAGIC_VER}"

  local XQ_PREFIX="/opt/X11"
  local CAIRO_PREFIX; CAIRO_PREFIX="$(brew --prefix cairo)"

  log "Configuring Magic (X11 Tk)…"
  ./configure \
    --prefix="$PREFIX" \
    --with-tcl="$X11_TCLTK_PREFIX/lib" \
    --with-tk="$X11_TCLTK_PREFIX/lib" \
    --with-cairo="${CAIRO_PREFIX}" \
    --x-includes="${XQ_PREFIX}/include" \
    --x-libraries="${XQ_PREFIX}/lib" \
    --enable-cairo-offscreen

  log "Building Magic…"
  make -j"$(sysctl -n hw.ncpu || echo 4)"
  log "Installing Magic to $PREFIX …"
  make install
}

# ===== Env + wrapper =====
write_env() {
  log "Updating environment at $ACTIVATE …"
  mkdir -p "$(dirname "$ACTIVATE")"
  cat >"$ACTIVATE" <<EOF
# SKY130 environment (Magic X11 build)
export EDA_PREFIX="$PREFIX"
export PATH="\$EDA_PREFIX/bin:\$PATH"
# Prefer our X11 Tcl/Tk at runtime
export TCLLIBPATH="$X11_TCLTK_PREFIX/lib"
export LD_LIBRARY_PATH="$X11_TCLTK_PREFIX/lib:\$LD_LIBRARY_PATH"
export DYLD_LIBRARY_PATH="$X11_TCLTK_PREFIX/lib:\$DYLD_LIBRARY_PATH"
# XQuartz DISPLAY (launchctl is more accurate; fallback provided)
export DISPLAY="\${DISPLAY:-\$(launchctl getenv DISPLAY 2>/dev/null || echo :0)}"
EOF
}

write_wrapper() {
  log "Writing wrapper $BIN_DIR/magic …"
  cat >"$BIN_DIR/magic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Ensure our env is loaded if present
ACT="$HOME/.eda/sky130/activate"
[ -f "$ACT" ] && # shellcheck disable=SC1090
source "$ACT"

exec "$EDA_PREFIX/bin/magic" -d X11 "$@"
EOF
  chmod +x "$BIN_DIR/magic"
  log "Wrapper created: $BIN_DIR/magic"
}

# ===== XQuartz bring-up & smoke test =====
start_x() {
  log "Ensuring XQuartz is running…"
  open -a XQuartz || true
  # give it a moment
  sleep 2
  # best-effort DISPLAY from launchd
  export DISPLAY="$(launchctl getenv DISPLAY || true)"
  [ -z "${DISPLAY:-}" ] && export DISPLAY=":0"
  command -v xhost >/dev/null 2>&1 && xhost +localhost >/dev/null 2>&1 || true
  log "DISPLAY=${DISPLAY:-unset}"
}

smoke_test() {
  log "Running Magic smoke test (no GUI draw, just init)…"
  # If GUI crashes immediately, this still returns interpreter version
  "$BIN_DIR/magic" -noconsole -dnull <<<'version; quit -noprompt' || true
  log "Now try launching GUI:  magic  (or: magic -d X11)"
}

# ===== Main =====
log "Using PREFIX: $PREFIX"
log "X11 Tcl/Tk prefix: $X11_TCLTK_PREFIX"
log "Env root: $ENVROOT"

ensure_brew
brew_deps
build_tcl
build_tk
build_magic
write_env
write_wrapper
start_x
smoke_test

log "Done. Source your env, then run Magic:"
echo '  source "$HOME/.eda/sky130/activate"'
echo '  magic    # should open X11 GUI'
