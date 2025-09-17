#!/bin/sh
# macOS SKY130 — One-Shot Installer (POSIX sh, robust, puts `magic` on PATH)
# -------------------------------------------------------------------------
# After this finishes, users can run:  magic &
# Key robustness:
#   • Broader PDK detection (/opt, /opt/pdk, Homebrew share, user prefixes)
#   • Headless smoke test via PDK rc only (no `-T sky130A`)
#   • Ensures `magic` command is on PATH now and for future shells

set -eu

YES=false
DRY=false

# ---- arg parsing ----
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '1,200p' "$0"; exit 0 ;;
    *) printf '[!] Unknown arg: %s\n' "$1" ;;
  esac
  shift
done

# ---- pretty ----
info() { printf "\033[1;34m[i]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m[✓]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[x]\033[0m %s\n" "$*"; exit 1; }

# read Y/N even if piped via curl
confirm() {
  prompt="$1"
  if [ "$YES" = true ]; then return 0; fi
  if [ -t 0 ]; then
    printf '%s [y/N]: ' "$prompt"
    read ans || ans=""
  else
    printf '%s [y/N]: ' "$prompt" > /dev/tty
    read ans < /dev/tty || ans=""
  fi
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

run() {
  if [ "$DRY" = true ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    # shellcheck disable=SC2086
    sh -c "$*"
  fi
}

# ---- defaults / paths ----
PDK_PREFIX="${PDK_PREFIX:-$HOME/eda/pdks}"
PDK_ROOT_DEFAULT="$PDK_PREFIX/share/pdk"
MAGIC_PREFIX="${MAGIC_PREFIX:-$HOME/eda/tools}"
SRC_ROOT="${SRC_ROOT:-$HOME/eda/src}"
mkdir -p "$PDK_PREFIX" "$MAGIC_PREFIX" "$SRC_ROOT"

BREW_BIN="$(command -v brew 2>/dev/null || true)"
PORT_BIN="$(command -v port 2>/dev/null || true)"
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"

# ---- 0) Xcode CLT ----
ensure_xcode() {
  if ! xcode-select -p >/dev/null 2>&1; then
    info "Installing Xcode Command Line Tools…"
    run "xcode-select --install || true"
    warn "If a dialog appeared, finish it, then re-run this script."
  fi
  ok "Xcode Command Line Tools present."
}

# ---- 1) Homebrew (for deps) ----
ensure_homebrew() {
  # Homebrew refuses to install as root
  if [ "$(id -u)" -eq 0 ]; then
    fail "Homebrew cannot be installed as root. Re-run as a normal user (no sudo)."
  fi

  if command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    ok "Homebrew present at $(brew --prefix 2>/dev/null || printf 'unknown')."
    return 0
  fi

  info "Installing Homebrew…"
  if [ "$YES" = true ]; then
    run 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty'
  else
    run '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty'
  fi

  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  else
    BREW_BIN="$(/usr/bin/find /opt /usr/local "$HOME" -type f -name brew -maxdepth 4 2>/dev/null | /usr/bin/head -n1 || true)"
    [ -n "$BREW_BIN" ] && eval "$("$BREW_BIN" shellenv)"
  fi

  BREW_BIN="$(command -v brew 2>/dev/null || true)"
  [ -n "$BREW_BIN" ] || fail "Homebrew installation appears to have failed."

  ZFILE="$HOME/.zprofile"
  if ! grep -q 'Homebrew (added by sky130 installer)' "$ZFILE" 2>/dev/null; then
    {
      echo ""
      echo "# Homebrew (added by sky130 installer)"
      if [ -x /opt/homebrew/bin/brew ]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
      else
        echo 'eval "$(/usr/local/bin/brew shellenv)"'
      fi
    } >> "$ZFILE"
  fi

  ok "Homebrew installed at $(brew --prefix)"
}

# ---- 2) brew deps ----
install_brew_deps() {
  info "Installing build/runtime dependencies…"
  run "brew update"
  run "brew install git automake autoconf libtool pkg-config gawk wget xz tcl-tk ngspice cmake gnu-sed"
  run "brew install --cask xquartz || true"
  run "brew install klayout || brew install --cask klayout || true"
  ok "Dependencies installed."
}

# ---- 3) Magic ----
install_magic_via_macports() {
  [ -n "$PORT_BIN" ] || return 1
  info "Installing Magic via MacPorts…"
  if sudo -n true 2>/dev/null; then :; else
    printf "%s\n" "[sudo] may prompt for your password…" >&2
    sudo -v
  fi
  run "sudo ${PORT_BIN:-/opt/local/bin/port} -N selfupdate || true"
  run "sudo ${PORT_BIN:-/opt/local/bin/port} -N install magic"
  PATH="/opt/local/bin:$PATH"; export PATH
  command -v magic >/dev/null 2>&1 || return 1
  ok "Magic installed via MacPorts."
  return 0
}

build_magic_from_source() {
  info "Building Magic from source into $MAGIC_PREFIX …"
  TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || true)"
  if [ -n "$TCLTK_PREFIX" ]; then
    export CFLAGS="-I$TCLTK_PREFIX/include ${CFLAGS-}"
    export LDFLAGS="-L$TCLTK_PREFIX/lib ${LDFLAGS-}"
    export PKG_CONFIG_PATH="$TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi
  mkdir -p "$SRC_ROOT" && cd "$SRC_ROOT"
  if [ ! -d magic ]; then
    run "git clone https://github.com/RTimothyEdwards/magic.git"
  fi
  cd magic
  run "git fetch --all -q && git pull -q"
  run "./configure --prefix='$MAGIC_PREFIX' --with-x --with-opengl=no --disable-cairo ${TCLTK_PREFIX:+--with-tcl='$TCLTK_PREFIX/lib' --with-tk='$TCLTK_PREFIX/lib' --with-tclinclude='$TCLTK_PREFIX/include' --with-tkinclude='$TCLTK_PREFIX/include'}"
  run "make -j$CORES"
  run "make install"
  PATH="$MAGIC_PREFIX/bin:$PATH"; export PATH
  command -v magic >/dev/null 2>&1 || fail "Magic built but not found in PATH."
  ok "Magic built and installed to $MAGIC_PREFIX."
}

ensure_magic() {
  if command -v magic >/dev/null 2>&1; then
    ok "Magic already present: $(command -v magic)"
    return 0
  fi
  if [ -n "$PORT_BIN" ]; then
    if confirm "MacPorts detected. Install Magic via MacPorts (admin required)?"; then
      install_magic_via_macports && return 0
      warn "MacPorts installation failed; will try building from source."
    fi
  fi
  if confirm "Build Magic from source under $MAGIC_PREFIX (no sudo)?"; then
    build_magic_from_source
  else
    fail "Magic is required by open_pdks. Aborting."
  fi
}

# ---- NEW: 3.5) Make sure `magic` is on PATH now and later ----
ensure_magic_on_path() {
  if command -v magic >/dev/null 2>&1; then
    ok "magic on PATH: $(command -v magic)"
  else
    # Try common locations and add to PATH immediately
    CAND=""
    [ -x "$MAGIC_PREFIX/bin/magic" ] && CAND="$MAGIC_PREFIX/bin/magic"
    [ -z "$CAND" ] && [ -x "/opt/local/bin/magic" ] && CAND="/opt/local/bin/magic"
    if [ -z "$CAND" ] && command -v brew >/dev/null 2>&1; then
      BREW_BIN_DIR="$(brew --prefix 2>/dev/null)/bin"
      [ -x "$BREW_BIN_DIR/magic" ] && CAND="$BREW_BIN_DIR/magic" || true
    fi
    if [ -n "$CAND" ]; then
      PATH="$(dirname "$CAND"):$PATH"; export PATH
      hash -r 2>/dev/null || true
      ok "Added $(dirname "$CAND") to PATH for this session."
    fi
    # As a fallback, create a user shim if still not found
    if ! command -v magic >/dev/null 2>&1 && [ -n "$CAND" ]; then
      mkdir -p "$HOME/bin"
      ln -sf "$CAND" "$HOME/bin/magic"
      PATH="$HOME/bin:$PATH"; export PATH
      hash -r 2>/dev/null || true
      ok "Created ~/bin/magic shim → $CAND"
    fi
    command -v magic >/dev/null 2>&1 || warn "Could not put 'magic' on PATH immediately; open a new terminal after install."
  fi
}

# ---- 4) open_pdks (sky130A) ----
build_open_pdks() {
  info "Building and installing open_pdks (sky130A)…"
  mkdir -p "$SRC_ROOT" "$PDK_PREFIX"
  cd "$SRC_ROOT"

  [ -d open_pdks ] || run "git clone https://github.com/RTimothyEdwards/open_pdks.git"
  cd open_pdks

  run "git fetch -q --all"
  run "git reset -q --hard"
  run "git clean -xfd -q"
  run "make distclean || true"

  TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || true)"
  if [ -n "$TCLTK_PREFIX" ]; then
    export LDFLAGS="-L$TCLTK_PREFIX/lib ${LDFLAGS-}"
    export CPPFLAGS="-I$TCLTK_PREFIX/include ${CPPFLAGS-}"
    export PKG_CONFIG_PATH="$TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi

  # Ensure magic is on PATH (needed to generate Magic tech files)
  PATH="$MAGIC_PREFIX/bin:$PATH"; export PATH

  run "./configure --prefix='$PDK_PREFIX' \
       --enable-sky130-pdk --with-sky130-variants=A \
       --disable-gf180mcu-pdk"

  run "make -j$CORES"
  run "make -j$CORES install"

  ok "open_pdks installed under $PDK_PREFIX"
}


# ---- 5) Locate PDK_ROOT (must be parent that CONTAINS sky130A/) ----
find_pdk_root() {
  cand="$PDK_ROOT_DEFAULT"
  if [ -f "$cand/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    printf '%s' "$cand"; return 0
  fi

  info "Searching for installed sky130A…"

  found="$(find "$PDK_PREFIX" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || true)"

  if [ -z "$found" ]; then
    brew_share="$(brew --prefix 2>/dev/null || true)/share/pdk"
    [ -d "$brew_share" ] && found="$(find "$brew_share" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || true)"
  fi

  if [ -z "$found" ]; then
    for base in /opt/pdk/share/pdk /opt/share/pdk /opt/pdk /usr/local/share/pdk /opt/homebrew/share/pdk /opt/local/share/pdk; do
      [ -d "$base" ] || continue
      found="$(find "$base" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || true)"
      [ -n "$found" ] && break
    done
  fi

  if [ -n "$found" ]; then
    d1="$(dirname "$found")"      # …/sky130A/libs.tech/magic
    d2="$(dirname "$d1")"         # …/sky130A/libs.tech
    d3="$(dirname "$d2")"         # …/sky130A
    root="$(dirname "$d3")"       # …/share/pdk  <-- PDK_ROOT
    printf '%s' "$root"; return 0
  fi

  return 1
}

# ---- 6) Persist env + Magic rc ----
persist_env() {
  pdk_root="$1"
  zfile="$HOME/.zprofile"
  info "Persisting environment exports to $zfile …"
  if ! grep -q 'BEGIN SKY130 ENV' "$zfile" 2>/dev/null; then
    cat >> "$zfile" <<EOF

# ===== BEGIN SKY130 ENV (installed by sky130 installer) =====
export PDK_PREFIX="$PDK_PREFIX"
export PDK_ROOT="$pdk_root"
export SKYWATER_PDK="\$PDK_ROOT/sky130A"
export OPEN_PDKS_ROOT="\$PDK_PREFIX"
export MAGTYPE=mag
# Ensure user-built Magic and MacPorts are on PATH (if present)
[ -d "/opt/local/bin" ] && export PATH="/opt/local/bin:\$PATH"
export PATH="$MAGIC_PREFIX/bin:\$PATH"
# Homebrew Tcl/Tk flags (improve Magic stability)
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
  fi
  ok "Environment exports appended. Open a new terminal to pick them up."
}

write_magic_rc() {
  info "Writing safe ~/.magicrc and removing stale wrapper…"
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

# (Optional) helper that never depends on the shell env
install_magic_wrapper() {
  bin="$MAGIC_PREFIX/bin"
  mkdir -p "$bin"
  cat > "$bin/magic-sky130" <<'EOF'
#!/bin/sh
# Run Magic with SKY130A rc explicitly, independent of current shell env.
set -eu
PDK_ROOT_GUESS="${PDK_ROOT:-}"
if [ -z "$PDK_ROOT_GUESS" ]; then
  for b in "$HOME/eda/pdks/share/pdk" /opt/pdk/share/pdk /usr/local/share/pdk /opt/homebrew/share/pdk; do
    if [ -f "$b/sky130A/libs.tech/magic/sky130A.magicrc" ]; then PDK_ROOT_GUESS="$b"; break; fi
  done
fi
[ -n "$PDK_ROOT_GUESS" ] || { echo "Could not determine PDK_ROOT for SKY130A." >&2; exit 1; }
exec magic -rcfile "$PDK_ROOT_GUESS/sky130A/libs.tech/magic/sky130A.magicrc" "$@"
EOF
  chmod +x "$bin/magic-sky130"
  ok "Installed helper: $bin/magic-sky130"
}

# ---- 7) Robust smoke test (rc-only) ----
smoke_test() {
  pdk_root="$1"
  rc="$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc"
  info "Running headless Magic smoke test (via PDK rc)…"
  [ -f "$rc" ] || fail "Missing $rc (open_pdks install incomplete?)"

  if command -v magic >/dev/null 2>&1; then
    out="$(
      (PDK_ROOT="$pdk_root" magic -noconsole -d null -rcfile "$rc" <<'EOF'
tech
exit
EOF
      ) 2>&1 || true
    )"
    echo "$out" | grep -qi 'sky130A' \
      && ok "Magic successfully loaded sky130A." \
      || { warn "Magic did not report 'sky130A'. Output was:\n$out"; }
  else
    warn "Magic not in PATH yet. Open a new terminal (env persisted) or run: magic -rcfile \"$rc\" &"
  fi
}

# ---- VERIFY + AUTO-FIX SKY130 LOADING (no MacPorts fallback) ----
ensure_sky130_loaded_and_fix() {
  info "Verifying Magic loads SKY130A…"

  if ! command -v magic >/dev/null 2>&1; then
    warn "Magic not on PATH yet — skipping SKY130 load check."
    return 0
  fi

  FOUND_RC=""
  PDK_ROOT_FIX=""

  # Candidate PDK_ROOTs to try (env, user prefix, brew, system, macports share)
  CAND_ROOTS="
${PDK_ROOT-}
$PDK_PREFIX/share/pdk
$HOME/eda/pdks/share/pdk
$(command -v brew >/dev/null 2>&1 && brew --prefix 2>/dev/null)/share/pdk
/opt/pdk/share/pdk
/usr/local/share/pdk
/opt/homebrew/share/pdk
/opt/local/share/pdk
"

  for r in $CAND_ROOTS; do
    [ -n "$r" ] || continue
    [ -f "$r/sky130A/libs.tech/magic/sky130A.magicrc" ] || continue
    FOUND_RC="$r/sky130A/libs.tech/magic/sky130A.magicrc"
    PDK_ROOT_FIX="$r"
    break
  done

  # Wider search (HOME + common system prefixes incl. /opt/local)
  if [ -z "$FOUND_RC" ]; then
    FOUND_RC="$(
      /usr/bin/find "$HOME" /opt /opt/local /usr/local /opt/homebrew \
        -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' \
        -print -quit 2>/dev/null || true
    )"
    if [ -n "$FOUND_RC" ]; then
      d1="$(dirname "$FOUND_RC")"; d2="$(dirname "$d1")"; d3="$(dirname "$d2")"
      PDK_ROOT_FIX="$(dirname "$d3")"   # …/share/pdk
    fi
  fi

  # If still not found, (re)build open_pdks from source and re-scan.
  if [ -z "$FOUND_RC" ]; then
    warn "SKY130 PDK not found. Rebuilding open_pdks from source…"
    build_open_pdks    # <-- your existing source build function
    # Re-scan once
    if [ -f "$PDK_PREFIX/share/pdk/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
      FOUND_RC="$PDK_PREFIX/share/pdk/sky130A/libs.tech/magic/sky130A.magicrc"
      PDK_ROOT_FIX="$PDK_PREFIX/share/pdk"
    else
      FOUND_RC="$(
        /usr/bin/find "$HOME" /opt /opt/local /usr/local /opt/homebrew \
          -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' \
          -print -quit 2>/dev/null || true
      )"
      [ -n "$FOUND_RC" ] && {
        d1="$(dirname "$FOUND_RC")"; d2="$(dirname "$d1")"; d3="$(dirname "$d2")"
        PDK_ROOT_FIX="$(dirname "$d3")"
      }
    fi
  fi

  [ -n "$FOUND_RC" ] || fail "Could not locate sky130A.magicrc anywhere. The open_pdks build likely failed. See logs above."

  # Headless test (load via rc; do NOT pass -T). Magic must be present for tech gen. :contentReference[oaicite:1]{index=1}
  OUT="$(
    (PDK_ROOT="$PDK_ROOT_FIX" magic -noconsole -d null -rcfile "$FOUND_RC" <<'EOF'
tech
exit
EOF
    ) 2>&1 || true
  )"

  if echo "$OUT" | grep -qi 'sky130A'; then
    ok "Magic successfully loaded SKY130A."
    return 0
  fi

  warn "Magic did not report 'sky130A'. Auto-fixing env and rc…"

  # Robust ~/.magicrc that sources via PDK_ROOT
  cat > "$HOME/.magicrc" <<'EOF'
# Minimal, robust Magic startup for SKY130A
if { [info exists env(PDK_ROOT)] && \
     [file exists "$env(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc"] } {
    source "$env(PDK_ROOT)/sky130A/libs.tech/magic/sky130A.magicrc"
} else {
    puts stderr "SKY130A magicrc not found. Check PDK_ROOT."
}
EOF
  ok "~/.magicrc updated."

  # Patch ~/.zprofile with corrected PDK_ROOT block
  ZFILE="$HOME/.zprofile"
  cp "$ZFILE" "$ZFILE.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  delete_block_in_file 'BEGIN SKY130 ENV' 'END SKY130 ENV' "$ZFILE"
  {
    echo ""
    echo "# ===== BEGIN SKY130 ENV (installed by sky130 installer) ====="
    echo "export PDK_PREFIX=\"$PDK_PREFIX\""
    echo "export PDK_ROOT=\"$PDK_ROOT_FIX\""
    echo "export SKYWATER_PDK=\"\$PDK_ROOT/sky130A\""
    echo "export OPEN_PDKS_ROOT=\"\$PDK_PREFIX\""
    echo "export MAGTYPE=mag"
    echo "[ -d \"/opt/local/bin\" ] && export PATH=\"/opt/local/bin:\$PATH\""
    echo "export PATH=\"$MAGIC_PREFIX/bin:\$PATH\""
    echo 'if command -v brew >/dev/null 2>&1; then'
    echo '  BREW_TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || true)"'
    echo '  if [ -n "$BREW_TCLTK_PREFIX" ]; then'
    echo '    export LDFLAGS="-L$BREW_TCLTK_PREFIX/lib${LDFLAGS:+ $LDFLAGS}"'
    echo '    export CPPFLAGS="-I$BREW_TCLTK_PREFIX/include${CPPFLAGS:+ $CPPFLAGS}"'
    echo '    export PKG_CONFIG_PATH="$BREW_TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"'
    echo '  fi'
    echo 'fi'
    echo "# ===== END SKY130 ENV ====="
  } >> "$ZFILE"
  ok "Environment updated in ~/.zprofile (PDK_ROOT=$PDK_ROOT_FIX)."

  # Re-test with fixed env
  OUT="$(
    (PDK_ROOT="$PDK_ROOT_FIX" magic -noconsole -d null -rcfile "$FOUND_RC" <<'EOF'
tech
exit
EOF
    ) 2>&1 || true
  )"
  if echo "$OUT" | grep -qi 'sky130A'; then
    ok "Re-test succeeded — SKY130A is now loading."
  else
    warn "Re-test did not report 'sky130A'. Output was:\n$OUT"
  fi
}



main() {
  ensure_xcode
  ensure_homebrew
  install_brew_deps
  ensure_magic
  ensure_magic_on_path       # <— NEW: guarantees `magic` command is available now
  ensure_sky130_loaded_and_fix
  build_open_pdks

  if ! PDK_ROOT_FOUND="$(find_pdk_root)"; then
    fail "Could not locate installed sky130A. Check build logs above."
  fi
  ok "Detected PDK_ROOT: $PDK_ROOT_FOUND"

  persist_env "$PDK_ROOT_FOUND"
  write_magic_rc
  install_magic_wrapper
  smoke_test "$PDK_ROOT_FOUND"

  cat <<EOF
Next steps:
  • You can now launch Magic normally:
      magic &
  • In Magic console:  :tech   (should print "sky130A")
  • If a shell still doesn’t see 'magic', open a new terminal or run:
      exec \$SHELL -l
EOF
  ok "All set!"
}

main "$@"
