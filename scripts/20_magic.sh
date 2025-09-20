#!/usr/bin/env bash
# remote-build-magic-macos.sh
#
# Run-from-GitHub one-shot builder for Magic (macOS).
# Works when piped from a raw GitHub URL (no local repo checkout needed).
#
# Example (git repo source):
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/scripts/remote-build-magic-macos.sh \
#   | bash -s -- --magic-url=https://github.com/<you>/magic.git --ref=main --prefix=$HOME/eda
#
# Example (tarball source):
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/scripts/remote-build-magic-macos.sh \
#   | bash -s -- --magic-url=https://github.com/RTimothyEdwards/magic/archive/refs/tags/8.3.552.tar.gz
#
# Options:
#   --magic-url=URL        Git URL (.git) or tarball (.tar.gz/.tgz/.zip) for Magic source (REQUIRED unless MAGIC_URL env set)
#   --ref=NAME             Git ref (branch/tag/commit) if --magic-url is a git repo (default: main)
#   --prefix=DIR           Install prefix (default: $HOME/eda)
#   --bootstrap-tcl86      Build a private Tcl/Tk 8.6 into $HOME/opt/tcl86 if not found
#   --tcltk-prefix=DIR     Use an explicit Tcl/Tk 8.6 prefix (contains bin/tclsh8.6 and bin/wish8.6)
#   --jobs=N               Parallel build jobs (default: CPU count)
#   --no-clean             Don’t run distclean/git clean in source tree (useful for dev iter)
#
# Key build choices:
#   - No X11: --with-x=no (prevents Xlib crashes; uses Aqua Tk)
#   - Pre-gen headers: runs scripts/makedbh with tclsh8.6 before make

set -euo pipefail

log()  { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
die()  { printf "[ERR ] %s\n" "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }
cpus() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# ---------- defaults ----------
MAGIC_URL="${MAGIC_URL:-}"   # allow env override
MAGIC_REF="main"
PREFIX="${HOME}/eda"
TCLTK_PREFIX="${TCLTK_PREFIX:-}"
BOOTSTRAP=0
DO_CLEAN=1
JOBS="$(cpus)"

# ---------- args ----------
for arg in "$@"; do
  case "$arg" in
    --magic-url=*)     MAGIC_URL="${arg#*=}";;
    --ref=*)           MAGIC_REF="${arg#*=}";;
    --prefix=*)        PREFIX="${arg#*=}";;
    --tcltk-prefix=*)  TCLTK_PREFIX="${arg#*=}";;
    --bootstrap-tcl86) BOOTSTRAP=1;;
    --jobs=*)          JOBS="${arg#*=}";;
    --no-clean)        DO_CLEAN=0;;
    *) die "Unknown option: $arg";;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "This script targets macOS."
require make
# clang is fine; prefer clang if gcc missing
command -v clang >/dev/null 2>&1 || require gcc
require tar
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "Need curl or wget"

if [[ -z "${MAGIC_URL}" ]]; then
  cat <<'EOF' >&2
[ERR ] --magic-url is required (git URL or tarball URL).
       Examples:
         --magic-url=https://github.com/<you>/magic.git --ref=main
         --magic-url=https://github.com/RTimothyEdwards/magic/archive/refs/tags/8.3.552.tar.gz
EOF
  exit 1
fi

# ---------- Tcl/Tk 8.6 discovery / bootstrap ----------
have() { command -v "$1" >/dev/null 2>&1; }

find_tcl86() {
  if [[ -n "$TCLTK_PREFIX" ]]; then
    [[ -x "$TCLTK_PREFIX/bin/tclsh8.6" && -x "$TCLTK_PREFIX/bin/wish8.6" ]] && { printf "%s\n" "$TCLTK_PREFIX"; return 0; }
    die "--tcltk-prefix does not contain tclsh8.6 + wish8.6: $TCLTK_PREFIX"
  fi
  # MacPorts
  [[ -x /opt/local/bin/tclsh8.6 && -x /opt/local/bin/wish8.6 ]] && { printf "%s\n" "/opt/local"; return 0; }
  # Homebrew: tcl-tk@8.6 or tcl-tk (if 8.6)
  if have brew; then
    if brew --prefix tcl-tk@8.6 >/dev/null 2>&1; then
      local p; p="$(brew --prefix tcl-tk@8.6)"
      [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { printf "%s\n" "$p"; return 0; }
    fi
    if brew --prefix tcl-tk >/dev/null 2>&1; then
      local p; p="$(brew --prefix tcl-tk)"
      [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { printf "%s\n" "$p"; return 0; }
    fi
  fi
  # user-local
  [[ -x "${HOME}/opt/tcl86/bin/tclsh8.6" && -x "${HOME}/opt/tcl86/bin/wish8.6" ]] && { printf "%s\n" "${HOME}/opt/tcl86"; return 0; }
  return 1
}

bootstrap_tcl86() {
  log "Bootstrapping Tcl/Tk 8.6 into \$HOME/opt/tcl86 ..."
  local work="/tmp/tcl86-build-$$"
  mkdir -p "$work" "$HOME/opt/tcl86"
  pushd "$work" >/dev/null

  local TCL_VER=8.6.14
  local TK_VER=8.6.14

  require curl
  curl -fsSL -o "tcl${TCL_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tcl${TCL_VER}-src.tar.gz"
  tar xf "tcl${TCL_VER}-src.tar.gz"
  pushd "tcl${TCL_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86"
    make -j"${JOBS}"; make install
  popd >/dev/null

  curl -fsSL -o "tk${TK_VER}-src.tar.gz" "https://downloads.sourceforge.net/tcl/tk${TK_VER}-src.tar.gz"
  tar xf "tk${TK_VER}-src.tar.gz"
  pushd "tk${TK_VER}/unix" >/dev/null
    ./configure --prefix="${HOME}/opt/tcl86" --with-tcl="${HOME}/opt/tcl86/lib"
    make -j"${JOBS}"; make install
  popd >/dev/null

  popd >/dev/null
  log "Tcl/Tk 8.6 installed at ${HOME}/opt/tcl86"
}

if ! TCLTK_PREFIX="$(find_tcl86)"; then
  if [[ "$BOOTSTRAP" -eq 1 ]]; then
    bootstrap_tcl86
    TCLTK_PREFIX="${HOME}/opt/tcl86"
  else
    cat <<'EOF' >&2
[ERR ] Tcl/Tk 8.6 not found.
      Install one (recommended) or re-run with --bootstrap-tcl86:

  MacPorts:
    sudo port install tcl tk +quartz

  Homebrew:
    brew install tcl-tk@8.6
    # or: brew install tcl-tk   (if it provides 8.6 on your setup)
EOF
    exit 1
  fi
fi

TCLSH="${TCLTK_PREFIX}/bin/tclsh8.6"
WISH="${TCLTK_PREFIX}/bin/wish8.6"
TCLTK_LIB="${TCLTK_PREFIX}/lib"
[[ -x "$TCLSH" ]] || die "Missing $TCLSH"
[[ -x "$WISH"  ]] || die "Missing $WISH"
log "Using Tcl/Tk 8.6 at: $TCLTK_PREFIX"

# ---------- fetch magic source into temp ----------
WORK="/tmp/magic-remote-build-$$"
SRC=""
cleanup() {
  [[ -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK"

fetch() {
  local url="$1"
  if [[ "$url" =~ \.git$ ]]; then
    require git
    log "Cloning $url @ ${MAGIC_REF} ..."
    git clone --depth 1 --branch "${MAGIC_REF}" "$url" "$WORK/src"
    SRC="$WORK/src"
  else
    log "Downloading source archive: $url"
    local fname="$WORK/src.tar"
    if have curl; then curl -fsSL "$url" -o "$fname"; else wget -q "$url" -O "$fname"; fi
    mkdir -p "$WORK/unpack"
    # Try common formats
    if tar -tf "$fname" >/dev/null 2>&1; then
      tar xf "$fname" -C "$WORK/unpack"
    else
      # zip fallback
      require unzip
      unzip -q "$fname" -d "$WORK/unpack"
    fi
    # pick the first top-level dir
    SRC="$(find "$WORK/unpack" -maxdepth 1 -type d ! -path "$WORK/unpack" | head -n1)"
    [[ -n "$SRC" ]] || die "Could not unpack source archive."
    log "Unpacked to: $SRC"
  fi
}

fetch "${MAGIC_URL}"

# ---------- build ----------
export PATH="${TCLTK_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:${PATH:-}"
unset DISPLAY  # ensure no X11

pushd "$SRC" >/dev/null

if [[ "$DO_CLEAN" -eq 1 ]]; then
  log "Cleaning source tree…"
  make distclean >/dev/null 2>&1 || true
  if command -v git >/dev/null 2>&1 && [[ -d .git ]]; then git clean -fdx || true; fi
fi

# Pre-generate the database header (prevents “database/database.h not found”)
log "Generating database/database.h with tclsh8.6…"
"$TCLSH" ./scripts/makedbh ./database/database.h.in ./database/database.h
[[ -f ./database/database.h ]] || die "makedbh did not produce database/database.h"

log "Configuring (no X11)…"
./configure \
  --prefix="${PREFIX}" \
  --with-x=no \
  --with-tcl="${TCLTK_LIB}" \
  --with-tk="${TCLTK_LIB}" \
  --with-tclsh="${TCLSH}" \
  --with-wish="${WISH}"

log "Building… (jobs=${JOBS})"
make -j"${JOBS}"

log "Installing to ${PREFIX}…"
make install

# Smoke test in headless mode (no GUI/X11 needed)
log "Smoke test (headless)…"
if ! "${PREFIX}/bin/magic" -dnull -noconsole -nowindow -rcfile /dev/null -T minimum <<<'quit' >/dev/null 2>&1; then
  warn "Headless test failed; Magic is installed but GUI/rcfile/tech may need attention."
fi

popd >/dev/null

cat <<EOF

Done.

Installed to: ${PREFIX}

Binaries you likely want in PATH:
  ${PREFIX}/bin/magic
  ${PREFIX}/bin/ext2spice

Add to your shell:
  export PATH="${PREFIX}/bin:\$PATH"

Notes:
  • Built with Aqua Tk (no X11) to avoid libX11 crashes on macOS.
  • If you later want X11 graphics, re-run without '--with-x=no' and ensure X11 headers/libs exist.

EOF
