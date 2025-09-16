#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Pretty output
info()  { printf "\033[1;34m[i]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[✓]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
fail()  { printf "\033[1;31m[x]\033[0m %s\n" "$*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Missing $1"; }

# Defaults (students can override via env before running)
PDK_PREFIX="${PDK_PREFIX:-$HOME/eda/pdks}"
PDK_ROOT_DEFAULT="$PDK_PREFIX/share/pdk"
BREW_BIN="$(command -v brew || true)"

ensure_xcode() {
  if ! xcode-select -p >/dev/null 2>&1; then
    info "Installing Xcode Command Line Tools…"
    xcode-select --install || true
    warn "If a dialog popped up, finish it, then rerun this script."
  fi
  ok "Xcode Command Line Tools present."
}

ensure_homebrew() {
  if [ -z "$BREW_BIN" ]; then
    info "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    BREW_BIN="$(command -v brew)"
  fi
  require_cmd brew
  ok "Homebrew present at $(brew --prefix)"
}

install_deps() {
  info "Installing build/runtime deps…"
  brew update
  brew install git automake autoconf libtool pkg-config gawk wget xz tcl-tk ngspice cmake
  brew install --cask xquartz
  # Useful GUIs from brew to avoid building from source on macOS
  brew install magic-netgen xschem klayout || true  # on some taps, magic/xschem are source; ok if already installed
  ok "Dependencies installed."
}

build_open_pdks() {
  info "Building and installing open_pdks (sky130A)…"
  mkdir -p "$HOME/eda/src" "$PDK_PREFIX"
  cd "$HOME/eda/src"
  if [ ! -d open_pdks ]; then
    git clone https://github.com/RTimothyEdwards/open_pdks.git
  fi
  cd open_pdks
  git fetch --all -q
  # Keep students on a known-good recent commit if you want:
  # git checkout <commit>

  make veryclean || true

  # Help builds find Homebrew Tcl/Tk
  local TCLTK_PREFIX
  TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || true)"
  export LDFLAGS="${TCLTK_PREFIX:+-L$TCLTK_PREFIX/lib} ${LDFLAGS:-}"
  export CPPFLAGS="${TCLTK_PREFIX:+-I$TCLTK_PREFIX/include} ${CPPFLAGS:-}"
  export PKG_CONFIG_PATH="${TCLTK_PREFIX:+$TCLTK_PREFIX/lib/pkgconfig}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

  ./configure --prefix="$PDK_PREFIX" --enable-sky130-pdk --with-sky130-variants=A
  make -j"$(sysctl -n hw.ncpu)"
  make -j"$(sysctl -n hw.ncpu)" install

  ok "open_pdks installed to $PDK_PREFIX"
}

detect_pdk_root() {
  # Prefer the canonical install path
  local candidate="$PDK_ROOT_DEFAULT"
  if [ -f "$candidate/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf "%s" "$candidate"
    return 0
  fi

  # Fallback: search under PDK_PREFIX, then under common brew share
  info "Searching for installed sky130A…"
  local found
  found="$(find "$PDK_PREFIX" -type f -path "*/sky130A/libs.tech/magic/sky130A.magicrc" -print -quit 2>/dev/null || true)"
  if [ -z "$found" ]; then
    local brew_share
    brew_share="$(brew --prefix 2>/dev/null)/share/pdk"
    found="$(find "$brew_share" -type f -path "*/sky130A/libs.tech/magic/sky130A.magicrc" -print -quit 2>/dev/null || true)"
  fi
  if [ -n "$found" ]; then
    # Walk up …/sky130A/libs.tech/magic/sky130A.magicrc -> PDK_ROOT (the parent dir that contains sky130A/)
    local pdk_root
    pdk_root="$(dirname "$(dirname "$(dirname "$found")")")"
    printf "%s" "$(dirname "$pdk_root")" | sed 's#/$##' | xargs -I{} printf "%s" "{}"
    return 0
  fi
  return 1
}

persist_shell_env() {
  local pdk_root="$1"
  local zfile="$HOME/.zprofile"
  info "Persisting environment to $zfile …"
  grep -q 'BEGIN SKY130 ENV' "$zfile" 2>/dev/null || {
    cat >> "$zfile" <<EOF

# ===== BEGIN SKY130 ENV (installed by mac sky130 installer) =====
export PDK_PREFIX="$PDK_PREFIX"
export PDK_ROOT="$pdk_root"
export SKYWATER_PDK="\$PDK_ROOT/sky130A"
export OPEN_PDKS_ROOT="\$PDK_PREFIX"
export MAGTYPE=mag
# Homebrew Tcl/Tk (improves Magic/Xschem stability)
if command -v brew >/dev/null 2>&1; then
  BREW_TCLTK_PREFIX="\$(brew --prefix tcl-tk 2>/dev/null || true)"
  if [ -n "\$BREW_TCLTK_PREFIX" ]; then
    export LDFLAGS="-L\$BREW_TCLTK_PREFIX/lib\${LDFLAGS:+ \$LDFLAGS}"
    export CPPFLAGS="-I\$BREW_TCLTK_PREFIX/include\${CPPFLAGS:+ \$CPPFLAGS}"
    export PKG_CONFIG_PATH="\$BREW_TCLTK_PREFIX/lib/pkgconfig\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}"
  fi
fi
# ===== END SKY130 ENV =====
EOF
  }
  ok "Environment exports appended. Open a new terminal for them to take effect."
}

fix_magic_rc() {
  info "Writing a safe ~/.magicrc and removing stale wrappers…"
  rm -f "$HOME/.config/sky130/rc_wrapper.tcl" 2>/dev/null || true
  cat > "$HOME/.magicrc" <<'EOF'
# Minimal, robust Magic startup for SKY130A
if { [info exists env(PDK_ROOT)] && \
     [file exists "$env(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc"] } {
    source "$env(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc"
} else {
    puts stderr "SKY130A magicrc not found. Check PDK_ROOT."
}
EOF
  ok "~/.magicrc configured."
}

smoke_check() {
  local pdk_root="$1"
  info "Checking PDK files…"
  test -f "$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc" || fail "sky130A.magicrc not found under $pdk_root"
  test -f "$pdk_root/sky130A/libs.tech/magic/sky130A.tech"    || warn "sky130A.tech not found (some builds generate it on first run)"

  info "Magic should now load sky130A. Try:"
  cat <<EOF
  magic -d XR -noconsole -rcfile "$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc" &
  # In the Magic console:  :tech    (should print 'sky130A')
EOF
  ok "Smoke checks passed."
}

main() {
  ensure_xcode
  ensure_homebrew
  install_deps
  build_open_pdks
  local pdk_root
  if ! pdk_root="$(detect_pdk_root)"; then
    fail "Could not locate installed sky130A. Check build logs above."
  fi
  ok "Detected PDK_ROOT: $pdk_root"
  persist_shell_env "$pdk_root"
  fix_magic_rc
  smoke_check "$pdk_root"
  ok "All set!"
}

main "$@"
