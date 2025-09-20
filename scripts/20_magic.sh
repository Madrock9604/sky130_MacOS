#!/usr/bin/env bash
# 20_magic.sh — build & install Magic from source on macOS (Apple Silicon or Intel)
# Designed to be run directly from GitHub, e.g.:
#   curl -fsSL https://raw.githubusercontent.com/Madrock9604/sky130_MacOS/refs/heads/main/scripts/20_magic.sh | bash -s --
#
# You can override defaults via env vars before running, e.g.:
#   PREFIX="$HOME/eda" MAGIC_URL="https://github.com/RTimothyEdwards/magic/archive/refs/tags/8.3.552.tar.gz" bash 20_magic.sh

set -euo pipefail

# -----------------------------
# Configurable defaults
# -----------------------------
: "${PREFIX:="$HOME/eda"}"                                      # install prefix
: "${JOBS:="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"}"       # build parallelism
: "${MAGIC_URL:="https://github.com/RTimothyEdwards/magic/archive/refs/tags/8.3.552.tar.gz"}"

# If you want to force specific toolchains, you can pre-set these:
: "${TCLSH:=}"             # e.g. /opt/local/bin/tclsh8.6 or /opt/homebrew/opt/tcl-tk/bin/tclsh8.6
: "${TCLTK_PREFIX:=}"      # e.g. /opt/local (MacPorts) or /opt/homebrew/opt/tcl-tk (Homebrew)
: "${WITH_X:=auto}"        # auto|yes|no
: "${X11_PREFIX:=/opt/X11}"# XQuartz default

log() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; exit 1; }

# -----------------------------
# Detect Tcl/Tk (MacPorts/Homebrew)
# -----------------------------
detect_tcltk() {
  if [[ -n "${TCLSH}" && -x "${TCLSH}" ]]; then
    log "Using TCLSH (pre-set): ${TCLSH}"
  else
    # Prefer Tcl/Tk 8.6 (Magic is known-good), then 9.0 if present.
    for c in \
      /opt/local/bin/tclsh8.6 \
      /opt/local/bin/tclsh \
      /opt/homebrew/opt/tcl-tk/bin/tclsh8.6 \
      /opt/homebrew/opt/tcl-tk/bin/tclsh9.0 \
      /usr/local/opt/tcl-tk/bin/tclsh8.6 \
      /usr/bin/tclsh; do
      if [[ -x "$c" ]]; then TCLSH="$c"; break; fi
    done
    [[ -n "${TCLSH}" ]] || die "Tcl/Tk not found. Install via MacPorts (sudo port install tk) or Homebrew (brew install tcl-tk)."
    log "Detected TCLSH: ${TCLSH}"
  fi

  if [[ -n "${TCLTK_PREFIX}" ]]; then
    log "Using TCL/TK prefix (pre-set): ${TCLTK_PREFIX}"
  else
    case "${TCLSH}" in
      /opt/local/*)                 TCLTK_PREFIX="/opt/local" ;;
      /opt/homebrew/opt/tcl-tk/*)   TCLTK_PREFIX="/opt/homebrew/opt/tcl-tk" ;;
      /usr/local/opt/tcl-tk/*)      TCLTK_PREFIX="/usr/local/opt/tcl-tk" ;;
      *)                            TCLTK_PREFIX="$(dirname "$(dirname "$TCLSH")")" ;;
    esac
    log "TCL/TK prefix: ${TCLTK_PREFIX}"
  fi
}

# -----------------------------
# Detect X11 (XQuartz)
# -----------------------------
detect_x11() {
  local have_headers="${X11_PREFIX}/include/X11/Xlib.h"
  local have_lib="${X11_PREFIX}/lib/libX11.dylib"
  if [[ "${WITH_X}" == "no" ]]; then
    WITH_X="no"
  elif [[ -f "${have_headers}" && -f "${have_lib}" ]]; then
    WITH_X="yes"
  else
    if [[ "${WITH_X}" == "yes" ]]; then
      warn "WITH_X=yes requested but XQuartz headers/libs not found under ${X11_PREFIX}. Proceeding without X11."
      WITH_X="no"
    else
      WITH_X="no"
    fi
  fi

  if [[ "${WITH_X}" == "yes" ]]; then
    log "X11 detected at ${X11_PREFIX} (XQuartz). Magic will build with GUI."
  else
    warn "X11 not found. Magic will build in batch mode (-dnull). Install XQuartz if you want GUI: https://www.xquartz.org/"
  fi
}

# -----------------------------
# Prep directories
# -----------------------------
prep_dirs() {
  mkdir -p "${PREFIX}/bin" "${PREFIX}/lib" "${PREFIX}/share"
}

# -----------------------------
# Download & unpack magic
# -----------------------------
fetch_and_unpack() {
  TMPROOT="$(mktemp -d -t magic-remote-build-XXXXXX)"
  trap 'rm -rf "${TMPROOT}"' EXIT

  log "Downloading source archive: ${MAGIC_URL}"
  ARCHIVE="${TMPROOT}/magic.tar.gz"
  curl -fL "${MAGIC_URL}" -o "${ARCHIVE}" || die "Download failed."

  log "Unpacking…"
  tar -xzf "${ARCHIVE}" -C "${TMPROOT}/" || die "Extract failed."

  # Determine top directory name inside tarball
  MAGIC_SRCDIR="$(tar -tzf "${ARCHIVE}" | head -1 | cut -d/ -f1)"
  [[ -d "${TMPROOT}/${MAGIC_SRCDIR}" ]] || die "Could not find source dir in archive."

  SRCDIR="${TMPROOT}/${MAGIC_SRCDIR}"
  log "Source directory: ${SRCDIR}"
}

# -----------------------------
# Generate database/database.h early (avoids parallel race)
# -----------------------------
generate_db_header() {
  log "Generating database/database.h with ${TCLSH}…"
  pushd "${SRCDIR}" >/dev/null

  # Ensure scripts/makedbh exists
  [[ -f "./scripts/makedbh" ]] || die "scripts/makedbh missing in source tree."

  # Run makedbh (same as what Makefile does, but we do it up-front)
  chmod +x ./scripts/makedbh || true
  "${TCLSH}" ./scripts/makedbh ./database/database.h.in ./database/database.h \
    || die "makedbh failed."

  popd >/dev/null
}

# -----------------------------
# Configure, build, install
# -----------------------------
build_and_install() {
  pushd "${SRCDIR}" >/dev/null

  # Flags to help find Tcl/Tk & X11 where needed.
  local cfg_args=()
  cfg_args+=( "--prefix=${PREFIX}" )
  cfg_args+=( "--with-tcl=${TCLTK_PREFIX}/lib" )
  cfg_args+=( "--with-tk=${TCLTK_PREFIX}/lib" )

  if [[ "${WITH_X}" == "yes" ]]; then
    cfg_args+=( "--with-x" "--x-includes=${X11_PREFIX}/include" "--x-libraries=${X11_PREFIX}/lib" )
  else
    cfg_args+=( "--with-x=no" )
  fi

  log "Configuring: ./configure ${cfg_args[*]}"
  ./configure "${cfg_args[@]}"

  log "Building (make -j${JOBS})…"
  make -j"${JOBS}"

  log "Installing (make install)…"
  make install

  popd >/dev/null
}

# -----------------------------
# Post-install notes
# -----------------------------
post_install() {
  local magic_bin="${PREFIX}/bin/magic"
  if [[ -x "${magic_bin}" ]]; then
    log "Magic installed: ${magic_bin}"
    cat <<EOF

Add to your PATH (if not already):
  export PATH="${PREFIX}/bin:\$PATH"

Run in batch mode (no GUI):
  magic -dnull -noconsole

EOF
    if [[ "${WITH_X}" == "yes" ]]; then
      cat <<'EOF'
GUI mode (requires XQuartz running):
  # Start XQuartz first, or ensure DISPLAY is set
  magic
EOF
      echo
    else
      warn "Built without X11. Rebuild with XQuartz installed to enable GUI."
    fi
  else
    die "Install completed but ${magic_bin} not found/executable."
  fi
}

# =============================
# Main
# =============================
log "Using install PREFIX: ${PREFIX}"
prep_dirs
detect_tcltk
detect_x11
fetch_and_unpack
generate_db_header
build_and_install
post_install
