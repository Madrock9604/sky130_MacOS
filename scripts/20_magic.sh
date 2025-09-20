#!/usr/bin/env bash
# scripts/20_magic.sh — run-from-GitHub installer for Magic on macOS

set -euo pipefail
log(){ printf "[INFO] %s\n" "$*"; }
err(){ printf "[ERR ] %s\n" "$*" >&2; exit 1; }

# ---------- defaults ----------
MAGIC_URL="${MAGIC_URL:-}"
MAGIC_REF="${MAGIC_REF:-main}"
PREFIX="${PREFIX:-$HOME/eda}"
TCLTK_PREFIX="${TCLTK_PREFIX:-}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
BOOTSTRAP="${BOOTSTRAP:-0}"   # 1 to auto-build Tcl/Tk 8.6 if missing

# ---------- args ----------
for a in "$@"; do
  case "$a" in
    --magic-url=*) MAGIC_URL="${a#*=}";;
    --ref=*)       MAGIC_REF="${a#*=}";;
    --prefix=*)    PREFIX="${a#*=}";;
    --tcltk-prefix=*) TCLTK_PREFIX="${a#*=}";;
    --jobs=*)      JOBS="${a#*=}";;
    --bootstrap-tcl86) BOOTSTRAP=1;;
    --no-clean)    NO_CLEAN=1;;
    *) err "Unknown option: $a";;
  esac
done

[[ "$(uname -s)" == Darwin ]] || err "This script targets macOS."
command -v make >/dev/null || err "Missing make"
command -v curl >/dev/null || command -v wget >/dev/null || err "Need curl or wget"
command -v tar  >/dev/null || err "Need tar"

# ---------- Tcl/Tk 8.6 detection ----------
have(){ command -v "$1" >/dev/null 2>&1; }
find_tcl86(){
  if [[ -n "$TCLTK_PREFIX" ]]; then
    [[ -x "$TCLTK_PREFIX/bin/tclsh8.6" && -x "$TCLTK_PREFIX/bin/wish8.6" ]] && { echo "$TCLTK_PREFIX"; return; }
    err "--tcltk-prefix does not contain tclsh8.6 + wish8.6"
  fi
  [[ -x /opt/local/bin/tclsh8.6 && -x /opt/local/bin/wish8.6 ]] && { echo /opt/local; return; }
  if have brew; then
    for f in tcl-tk@8.6 tcl-tk; do
      if brew --prefix "$f" >/dev/null 2>&1; then
        p="$(brew --prefix "$f")"
        [[ -x "$p/bin/tclsh8.6" && -x "$p/bin/wish8.6" ]] && { echo "$p"; return; }
      fi
    done
  fi
  [[ -x "$HOME/opt/tcl86/bin/tclsh8.6" && -x "$HOME/opt/tcl86/bin/wish8.6" ]] && { echo "$HOME/opt/tcl86"; return; }
  return 1
}
bootstrap_tcl86(){
  log "Bootstrapping Tcl/Tk 8.6 into \$HOME/opt/tcl86 ..."
  work="/tmp/tcl86-$$"; mkdir -p "$work" "$HOME/opt/tcl86"; pushd "$work" >/dev/null
  TCL_VER=8.6.14; TK_VER=8.6.14
  curl -fsSL -o tcl.tgz "https://downloads.sourceforge.net/tcl/tcl${TCL_VER}-src.tar.gz"
  tar xf tcl.tgz; pushd "tcl${TCL_VER}/unix" >/dev/null; ./configure --prefix="$HOME/opt/tcl86"; make -j"$JOBS"; make install; popd >/dev/null
  curl -fsSL -o tk.tgz  "https://downloads.sourceforge.net/tcl/tk${TK_VER}-src.tar.gz"
  tar xf tk.tgz;  pushd "tk${TK_VER}/unix"  >/dev/null; ./configure --prefix="$HOME/opt/tcl86" --with-tcl="$HOME/opt/tcl86/lib"; make -j"$JOBS"; make install; popd >/dev/null
  popd >/dev/null
}
if ! TCLTK_PREFIX="$(find_tcl86)"; then
  [[ "$BOOTSTRAP" -eq 1 ]] || err $'Tcl/Tk 8.6 not found.\nInstall via MacPorts (tcl tk +quartz) or Homebrew (tcl-tk@8.6), or pass --bootstrap-tcl86.'
  bootstrap_tcl86
  TCLTK_PREFIX="$HOME/opt/tcl86"
fi
TCLSH="$TCLTK_PREFIX/bin/tclsh8.6"; WISH="$TCLTK_PREFIX/bin/wish8.6"; TCLTK_LIB="$TCLTK_PREFIX/lib"
log "Using Tcl/Tk 8.6 at: $TCLTK_PREFIX"

# ---------- fetch source ----------
WORK="/tmp/magic-remote-build-$$"; trap 'rm -rf "$WORK"' EXIT; mkdir -p "$WORK"
fetch(){
  local url="$1"
  if [[ "$url" =~ \.git$ ]]; then
    command -v git >/dev/null || err "Need git for repo URL"
    log "Cloning $url @ $MAGIC_REF ..."
    git clone --depth 1 --branch "$MAGIC_REF" "$url" "$WORK/src"
  else
    log "Downloading source archive: $url"
    local f="$WORK/src.tar"; if command -v curl >/dev/null; then curl -fsSL "$url" -o "$f"; else wget -q "$url" -O "$f"; fi
    mkdir -p "$WORK/unpack"; tar xf "$f" -C "$WORK/unpack"
    mv "$(find "$WORK/unpack" -mindepth 1 -maxdepth 1 -type d | head -n1)" "$WORK/src"
  fi
}
[[ -n "$MAGIC_URL" ]] || err "--magic-url is required"
fetch "$MAGIC_URL"
log "Unpacked to: $WORK/src"

# ---------- build ----------
export PATH="$TCLTK_PREFIX/bin:$PATH"
unset DISPLAY   # force non-X11 path

cd "$WORK/src"
[[ "${NO_CLEAN:-0}" -eq 1 ]] || { make distclean >/dev/null 2>&1 || true; git clean -fdx >/dev/null 2>&1 || true; }

log "Configuring (disable X11)…"
./configure \
  --prefix="$PREFIX" \
  --with-x=no \
  --with-tcl="$TCLTK_LIB" \
  --with-tk="$TCLTK_LIB" \
  --with-tclsh="$TCLSH" \
  --with-wish="$WISH"

# Generate the header *after* configure, via make’s own rule
log "Generating database/database.h…"
make -j1 database/database.h

log "Building… (jobs=$JOBS)"
make -j"$JOBS"

log "Installing to $PREFIX…"
make install

log "Smoke test (headless)…"
if ! "$PREFIX/bin/magic" -dnull -noconsole -nowindow -rcfile /dev/null -T minimum <<<'quit' >/dev/null 2>&1; then
  printf "[WARN] Headless test failed; Magic installed but GUI/techfile may need attention.\n"
fi

cat <<EOF

Done.

Installed to: $PREFIX
Add to PATH:
  export PATH="$PREFIX/bin:\$PATH"

Notes:
  • Built with Aqua Tk (no X11) to avoid libX11/wish segfaults.
  • Rebuild without --with-x=no only after you have working X11 headers/libs.
EOF
