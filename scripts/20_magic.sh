#!/usr/bin/env bash
# scripts/20_magic.sh
# Build & install Magic VLSI on macOS with XQuartz + X11 Tcl/Tk.
# - No local edits needed beyond running this script from GitHub.
# - Solves the database/database.h generation race by serializing makedbh.
# - Installs to ${PREFIX:-$HOME/eda}
# - Uses X11 Tcl/Tk from one of: ~/.eda/x11-tcltk, /opt/local, /usr/local/opt2/tcl-tk, /opt/homebrew/opt/tcl-tk (last resort).

set -Eeuo pipefail

# -------------------------
# Helpers
# -------------------------
log() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command '$1' not found."
}

# -------------------------
# Settings (overridable via env)
# -------------------------
PREFIX="${PREFIX:-"$HOME/eda"}"
MAGIC_VER="${MAGIC_VER:-8.3.552}"   # tag from R. Timothy Edwards repo
JOBS="${JOBS:-"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"}"

# Known X11 Tcl/Tk homes to probe (first hit wins)
X11_TCLTK_CANDIDATES=(
  "$HOME/.eda/x11-tcltk"
  "/opt/local"                 # MacPorts
  "/usr/local/opt2/tcl-tk"     # From the manual X11 build instructions
  "/opt/homebrew/opt/tcl-tk"   # Homebrew (often Aqua, may still work)
)

# -------------------------
# Pre-flight
# -------------------------
case "$(uname -s)" in
  Darwin) : ;;
  *) err "This script targets macOS (Darwin) only." ;;
esac

require_cmd curl
require_cmd tar
require_cmd make
require_cmd gcc

# XQuartz check
if [ -d "/opt/X11" ]; then
  log "X11 detected at /opt/X11 (XQuartz)."
else
  warn "XQuartz not found at /opt/X11."
  warn "Install XQuartz first (Homebrew: 'brew install --cask xquartz'), then re-run."
  # We won't hard-fail; you can still do a headless build, but GUI won't work.
fi

# Tcl/Tk (X11) probe
TCLTK_PREFIX=""
for d in "${X11_TCLTK_CANDIDATES[@]}"; do
  if [ -d "$d" ] && [ -e "$d/lib" ]; then
    TCLTK_PREFIX="$d"
    break
  fi
done
[ -n "$TCLTK_PREFIX" ] || warn "Could not find an X11 Tcl/Tk prefix. We'll still try, but you may get 'X11: no' in configure."

# A tclsh to run makedbh
TCLSH=""
for cand in \
  "$TCLTK_PREFIX/bin/tclsh8.6" \
  "$TCLTK_PREFIX/bin/tclsh" \
  "$(command -v tclsh8.6 || true)" \
  "$(command -v tclsh || true)"
do
  if [ -n "${cand:-}" ] && [ -x "$cand" ]; then TCLSH="$cand"; break; fi
done
[ -n "$TCLSH" ] || warn "No 'tclsh' found yet; configure may still locate Tcl/Tk via --with-tcl/--with-tk paths."

# Install root
mkdir -p "$PREFIX"/{bin,lib} >/dev/null 2>&1 || true
log "Using install PREFIX: $PREFIX"

# Optional project env
ACTIVATE="$HOME/.eda/sky130/activate"
if [ -f "$ACTIVATE" ]; then
  log "Found project environment at: $ACTIVATE"
else
  warn "Project env '$ACTIVATE' not found. We'll proceed anyway."
fi

# -------------------------
# Fetch Magic source
# -------------------------
TAG="$MAGIC_VER"
ARCHIVE_URL="https://github.com/RTimothyEdwards/magic/archive/refs/tags/${TAG}.tar.gz"

BUILDROOT="$(mktemp -d -t magic-remote-build-XXXXXX)"
cleanup() { rm -rf "$BUILDROOT"; }
trap cleanup EXIT

log "Downloading Magic ${TAG}…"
curl -fsSL "$ARCHIVE_URL" -o "$BUILDROOT/magic-${TAG}.tar.gz" \
  || err "Failed to download $ARCHIVE_URL"

log "Unpacking…"
tar -xzf "$BUILDROOT/magic-${TAG}.tar.gz" -C "$BUILDROOT"
SRCDIR="$(cd "$BUILDROOT"/magic-"$TAG" && pwd)"
[ -d "$SRCDIR" ] || err "Unpack failed; source dir missing."

log "Source directory: $SRCDIR"
