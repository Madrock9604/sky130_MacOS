#!/usr/bin/env bash
#
# 20_magic.sh — install Magic (VLSI) on macOS
# - If MacPorts is present: uses `port install magic +x11`
# - Else: uses Homebrew for deps and builds from source tag
#
# Config via env:
#   PREFIX          install prefix (default: "$HOME/eda")
#   MAGIC_VER       git tag to build when using source (default: "8.3.552")
#   ACTIVATE_FILE   env file to source in wrapper (default: "$HOME/.eda/sky130/activate")
#   MAKE_JOBS       parallelism for make (default: CPU count)
#
set -euo pipefail

# ------------- config -------------
PREFIX="${PREFIX:-$HOME/eda}"
MAGIC_VER="${MAGIC_VER:-8.3.552}"
ACTIVATE_FILE="${ACTIVATE_FILE:-$HOME/.eda/sky130/activate}"
MAKE_JOBS="${MAKE_JOBS:-$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

BIN_DIR="$PREFIX/bin"
WRAPPER="$BIN_DIR/magic"
LOG_PREFIX="[MAGIC]"

say() { printf "%s %s\n" "$LOG_PREFIX" "$*"; }
die() { printf "%s ERROR: %s\n" "$LOG_PREFIX" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ensure_dirs() {
  mkdir -p "$BIN_DIR"
}

make_wrapper() {
  ensure_dirs
  cat >"$WRAPPER" <<EOF
#!/usr/bin/env bash
# Wrapper to run magic inside your sky130 environment
set -euo pipefail
if [ -f "$ACTIVATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ACTIVATE_FILE"
fi
exec magic "\$@"
EOF
  chmod +x "$WRAPPER"
  say "Installed wrapper: $WRAPPER"
}

install_via_macports() {
  say "MacPorts detected — installing magic via MacPorts…"
  # Update ports index
  sudo port -N selfupdate
  # Install magic with X11 support (variants names may vary; +x11 is default on macOS)
  sudo port -N install magic +x11
  local magic_bin="/opt/local/bin/magic"
  [ -x "$magic_bin" ] || die "MacPorts magic not found at $magic_bin after install."

  # Symlink to your toolchain bin for consistency
  ensure_dirs
  ln -sf "$magic_bin" "$BIN_DIR/magic"
  say "Linked $magic_bin -> $BIN_DIR/magic"

  make_wrapper
  say "Done (MacPorts)."
}

install_via_brew_source() {
  say "Falling back to Homebrew + source build…"
  have brew || die "Homebrew not found. Install Homebrew or MacPorts."

  # Ensure deps
  brew update
  # Tcl/Tk and XQuartz for X11 GUI
  brew list --versions tcl-tk >/dev/null 2>&1 || brew install tcl-tk
  # XQuartz is cask (installs under /opt/X11). It may prompt GUI installer the first time.
  if ! [ -d "/opt/X11" ]; then
    brew install --cask xquartz
    say "XQuartz installed. You may need to log out/in once if X11 fails to start."
  fi
  brew list --versions git >/dev/null 2>&1 || brew install git
  brew list --versions pkg-config >/dev/null 2>&1 || brew install pkg-config

  # Paths for headers/libs
  local HBTCL_H="/opt/homebrew/opt/tcl-tk/include"
  local HBTCL_L="/opt/homebrew/opt/tcl-tk/lib"
  local X11_H="/opt/X11/include"
  local X11_L="/opt/X11/lib"

  # Build workspace
  local TMPROOT
  TMPROOT="$(mktemp -d -t magic-src-XXXXXX)"
  trap 'rm -rf "$TMPROOT"' EXIT

  say "Cloning Magic tag $MAGIC_VER…"
  git clone --depth 1 --branch "$MAGIC_VER" https://github.com/RTimothyEdwards/magic.git "$TMPROOT/magic"
  cd "$TMPROOT/magic"

  # Configure flags
  export CPPFLAGS="${CPPFLAGS:-} -I$HBTCL_H -I$X11_H"
  export LDFLAGS="${LDFLAGS:-} -L$HBTCL_L -L$X11_L"
  export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}:$HBTCL_L/pkgconfig"

  say "Configuring…"
  ./configure \
    --prefix="$PREFIX" \
    --with-interpreter=tcl \
    --enable-tcl=yes \
    --enable-tk=yes \
    --with-tcl="$HBTCL_L" \
    --with-tk="$HBTCL_L" \
    --x-includes="$X11_H" \
    --x-libraries="$X11_L"

  say "Building (make -j$MAKE_JOBS)…"
  make -j"$MAKE_JOBS"

  say "Installing to $PREFIX…"
  make install

  make_wrapper
  say "Done (source build)."
}

ensure_env_note() {
  # Suggest PATH export for the user environment file if needed
  if [ -f "$ACTIVATE_FILE" ]; then
    if ! grep -qs "$BIN_DIR" "$ACTIVATE_FILE"; then
      cat >>"$ACTIVATE_FILE" <<EOF

# Added by 20_magic.sh
export PATH="$BIN_DIR:\$PATH"
# If you need XQuartz DISPLAY, uncomment:
# export DISPLAY=":0"
EOF
      say "Appended PATH to $ACTIVATE_FILE"
    fi
  else
    say "Note: env file $ACTIVATE_FILE not found. Create it and add:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
  fi
}

main() {
  say "Installing Magic into: $PREFIX"
  say "Using env file: $ACTIVATE_FILE"

  if have port; then
    install_via_macports
  else
    install_via_brew_source
  fi

  ensure_env_note

  say "Verify with:  source \"$ACTIVATE_FILE\" && magic -version"
}

main "$@"
