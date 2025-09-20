#!/usr/bin/env bash
# scripts/20_magic.sh
# Install Magic (VLSI layout tool) using MacPorts or Homebrew, then create a wrapper
# in $PREFIX/bin/magic that sources ~/.eda/sky130/activate and execs the real binary.

set -euo pipefail

# ---------- Config ----------
: "${PREFIX:="$HOME/eda"}"                         # install root for wrappers
: "${ENV_FILE:="$HOME/.eda/sky130/activate"}"     # environment activation file
BIN_DIR="$PREFIX/bin"

# Pretty log helpers
info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERR ] %s\n' "$*" >&2; exit 1; }

# Ensure dirs
mkdir -p "$BIN_DIR"

# ---------- Detect package managers ----------
have() { command -v "$1" >/dev/null 2>&1; }

PM="none"
if have port; then
  PM="macports"
elif have brew; then
  PM="homebrew"
fi

# ---------- Install Magic ----------
case "$PM" in
  macports)
    info "MacPorts detected. Installing magic via MacPorts..."
    # -N = assume yes to prompts; remove -N if you prefer interactivity
    sudo port -N selfupdate || warn "MacPorts selfupdate failed; continuing"
    sudo port -N install magic || error "Failed to install 'magic' via MacPorts"
    MAGIC_BIN="/opt/local/bin/magic"
    ;;

  homebrew)
    info "Homebrew detected. Installing magic via Homebrew..."
    brew update || warn "brew update failed; continuing"
    # Prefer tcl-tk keg from brew if you rely on it elsewhere
    brew install magic || error "Failed to install 'magic' via Homebrew"
    # resolve magic path from brew first, then PATH
    if brew_prefix_magic="$(brew --prefix magic 2>/dev/null)"; then
      if [ -x "${brew_prefix_magic}/bin/magic" ]; then
        MAGIC_BIN="${brew_prefix_magic}/bin/magic"
      fi
    fi
    MAGIC_BIN="${MAGIC_BIN:-"$(command -v magic)"}"
    [ -x "${MAGIC_BIN:-/nonexistent}" ] || error "magic not found after brew install"
    ;;

  *)
    error "No supported package manager found. Install MacPorts or Homebrew, then re-run."
    ;;
esac

info "Using magic binary: $MAGIC_BIN"

# ---------- Create wrapper in $PREFIX/bin ----------
WRAPPER="$BIN_DIR/magic"
info "Writing wrapper: $WRAPPER"
# Remove any previous file (including broken symlinks) safely
if [ -L "$WRAPPER" ] || [ -f "$WRAPPER" ]; then
  rm -f "$WRAPPER"
fi

cat >"$WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ACTIVATE_FILE="\${ACTIVATE_FILE:-$ENV_FILE}"
if [ -f "\$ACTIVATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "\$ACTIVATE_FILE"
fi
exec "$MAGIC_BIN" "\$@"
EOF
chmod +x "$WRAPPER"

# ---------- Report ----------
info "Wrapper created at: $WRAPPER"
info "Update your PATH or source your environment, then run: magic -version"

# Best-effort smoke test (non-fatal if env needs to be sourced first)
if "$WRAPPER" -version >/dev/null 2>&1; then
  info "magic -version: $("$WRAPPER" -version 2>/dev/null)"
else
  warn "Could not run magic yet. Make sure \$PATH includes '$BIN_DIR' or source your env:"
  warn "  source \"$ENV_FILE\"  # then: magic -version"
fi

info "Done."
