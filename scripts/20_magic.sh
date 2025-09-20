#!/usr/bin/env bash
# Install Magic from source on macOS using only this script.
# Safe to run directly from a GitHub raw link.

set -euo pipefail

log(){ printf "[INFO] %s\n" "$*"; }
warn(){ printf "[WARN] %s\n" "$*" >&2; }
die(){ printf "[ERR ] %s\n" "$*" >&2; exit 1; }

# -------------------- Config (override via env or flags) --------------------
# Magic release tarball; change MAGIC_URL if you want a different version.
MAGIC_URL="${MAGIC_URL:-https://github.com/RTimothyEdwards/magic/archive/refs/tags/8.3.552.tar.gz}"

# Where to install Magic
PREFIX="${PREFIX:-$HOME/eda}"

# Optionally point at a specific Tcl/Tk 8.6 prefix (contains bin/tclsh8.6, bin/wish8.6)
TCLTK_PREFIX="${TCLTK_PREFIX:-}"

# Parallel build jobs
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# -------------------- CLI flags --------------------
usage(){
  cat <<EOF
Usage: $0 [options]

Options:
  --prefix=DIR           Install prefix (default: \$HOME/eda)
  --magic-url=URL        Source tarball URL (default: $MAGIC_URL)
  --tcltk-prefix=DIR     Tcl/Tk 8.6 prefix (has bin/tclsh8.6 and bin/wish8.6)
  --jobs=N               make -jN (default: detected CPU count)
  -h|--help              Show this help

Environment overrides:
  PREFIX, MAGIC_URL, TCLTK_PREFIX, JOBS
EOF
}

for a in "$@"; do
  case "$a" in
    --prefix=*)        PREFIX="${a#*=}";;
    --magic-url=*)     MAGIC_URL="${a#*=}";;
    --tcltk-prefix=*)  TCLTK_PREFIX="${a#*=}";;
    --jobs=*)          JOBS="${a#*=}";;
    -h|--help)         usage; exit 0;;
    *) die "Unknown option: $a. Try --help";;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "This script targets macOS."
command -v tar >/dev/null || die "tar not found"
command -v make >/dev/null || die "make not found"
if ! command -v curl >/dev/null && ! command -v wget >/dev/null; then
  die "Need curl or wget"
fi

# -------------------- Find Tcl/Tk 8.6 --------------------
have(){ command -v "$1" >/dev/null 2>&1; }

find_tcl86(){
  # 1) explicit
  if [[ -n "$TCLTK_PREFIX" ]]; then
    [[ -x "$TCLTK_PREFIX/bin/tclsh8.6" && -x "$TCLTK_PREFIX/bin/wish8.6" ]] \
      && { echo "$TCLTK_PREFIX"; return; }
    die "--tcltk-prefix does not contain tclsh8.6 and wish8.6: $TCLTK_PREFIX"
  fi
  # 2) MacPorts
  [[ -x /opt/local/bin/tclsh8.6 && -x /opt/local/bin/wish8.6 ]] && { echo /opt/local; return; }
  # 3) Homebrew (tcl-tk@8.6 or tcl-tk)
  if have brew; then
    for f in tcl-tk@8.6 tcl-tk; do
      if brew --prefix "$f" >/dev/null 2>&1; then
        p="$(brew --prefix "$f")"
        [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { echo "$p"; return; }
      fi
    done
  fi
  # 4) common custom location
  [[ -x "$HOME/opt/tcl86/bin/tclsh8.6" && -x "$HOME/opt/tcl86/bin/wish8.6" ]] \
    && { echo "$HOME/opt/tcl86"; return; }
  return 1
}

if ! TCLTK_PREFIX="$(find_tcl86)"; then
  cat <<'EOF' >&2
[ERR ] Tcl/Tk 8.6 not found.
       Please install via MacPorts (sudo port install tcl tk +quartz) or Homebrew:
         brew install tcl-tk@8.6
       Then re-run, or pass --tcltk-prefix=DIR.
EOF
  exit 1
fi

TCLSH="$TCLTK_PREFIX/bin/tclsh8.6"
WISH="$TCLTK_PREFIX/bin/wish8.6"
TCLTK_LIB="$TCLTK_PREFIX/lib"
log "Using Tcl/Tk 8.6 at: $TCLTK_PREFIX"

# -------------------- Fetch & unpack Magic --------------------
WORK="$(mktemp -d /tmp/magic-build-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

SRC_TGZ="$WORK/src.tgz"
if command -v curl >/dev/null; then
  log "Downloading Magic: $MAGIC_URL"
  curl -fsSL "$MAGIC_URL" -o "$SRC_TGZ"
else
  log "Downloading Magic (wget): $MAGIC_URL"
  wget -q "$MAGIC_URL" -O "$SRC_TGZ"
fi

log "Unpacking…"
mkdir -p "$WORK/unpack"
tar xf "$SRC_TGZ" -C "$WORK/unpack"
# take the first top-level dir as source root
SRC_DIR="$(find "$WORK/unpack" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -n "$SRC_DIR" && -d "$SRC_DIR" ]] || die "Could not locate unpacked source directory"
log "Source at: $SRC_DIR"

# -------------------- Configure, build, install --------------------
export PATH="$TCLTK_PREFIX/bin:$PATH"

cd "$SRC_DIR"

# If coming from a clean tarball, these are no-ops; we silence errors.
make distclean >/dev/null 2>&1 || true

# On your machine, X11/wish path was segfaulting. We explicitly disable X11.
# Also skip OpenGL/Cairo to keep it simple.
log "Configuring (disable X11/OpenGL/Cairo)…"
./configure \
  --prefix="$PREFIX" \
  --with-x=no \
  --with-opengl=no \
  --with-cairo=no \
  --with-tcl="$TCLTK_LIB" \
  --with-tk="$TCLTK_LIB" \
  --with-tclsh="$TCLSH" \
  --with-wish="$WISH"

# Make sure the auto-generated header exists (do this *after* configure)
log "Generating database/database.h…"
make -j1 database/database.h

log "Building (jobs=$JOBS)…"
make -j"$JOBS"

log "Installing to $PREFIX…"
make install

# -------------------- Quick smoke test (headless) --------------------
if "$PREFIX/bin/magic" -dnull -noconsole -nowindow -rcfile /dev/null -T minimum <<<'quit' >/dev/null 2>&1; then
  log "Headless smoke test passed."
else
  warn "Headless smoke test failed; Magic installed, but GUI/techfile may need attention."
fi

cat <<EOF

✅ Done.

Installed to: $PREFIX
Add to your shell rc:
  export PATH="$PREFIX/bin:\$PATH"

Notes:
  • Built **without X11** to avoid libX11/wish crashes on your setup.
  • If you later want a GUI via X11, rebuild without --with-x=no *after* you have working XQuartz/X11 headers and libs.
EOF
