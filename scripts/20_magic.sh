#!/bin/sh
# macOS SKY130 — One-Shot Installer (POSIX sh, Homebrew-only)
# -----------------------------------------------------------
# After this finishes, students can run:  magic &
# - Uses Homebrew only (no MacPorts).
# - Builds Magic with Cocoa Tk (no XQuartz needed).
# - Installs SKY130A via open_pdks.
# - Persists env for zsh (~/.zprofile + ~/.zshrc).
# - Forces 'magic' to resolve to the Cocoa build via ~/bin shim.
set -eu

YES=false
DRY=false

# ---------- args ----------
while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=true ;;
    --dry-run) DRY=true ;;
    -h|--help) sed -n '1,160p' "$0"; exit 0 ;;
    *) printf '[!] Unknown arg: %s\n' "$1" ;;
  esac
  shift
done

# ---------- pretty ----------
info(){ printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok(){   printf '\033[1;32m[✓]\\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail(){ printf '\033[1;31m[x]\033[0m %s\n' "$*"; exit 1; }

confirm(){
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

run(){
  if [ "$DRY" = true ]; then
    printf 'DRY-RUN: %s\n' "$*"
  else
    sh -c "$*"
  fi
}

# ---------- defaults ----------
PDK_PREFIX="${PDK_PREFIX:-$HOME/eda/pdks}"
PDK_ROOT_DEFAULT="$PDK_PREFIX/share/pdk"
MAGIC_PREFIX="${MAGIC_PREFIX:-$HOME/eda/tools}"
SRC_ROOT="${SRC_ROOT:-$HOME/eda/src}"
CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
mkdir -p "$PDK_PREFIX" "$MAGIC_PREFIX" "$SRC_ROOT" "$HOME/bin"

# ---------- helpers ----------
delete_block_in_file(){ # delete BEGIN..END block in a file
  start="$1"; end="$2"; f="$3"
  [ -f "$f" ] || return 0
  tmp="$f.tmp.$(date +%s)"
  awk 'BEGIN{del=0} {if($0~start){del=1} if(!del)print; if($0~end && del==1){del=0}}' \
      start="$start" end="$end" "$f" > "$tmp" && mv "$tmp" "$f"
}

# ---------- 0) Xcode CLT ----------
ensure_xcode(){
  if ! xcode-select -p >/dev/null 2>&1; then
    info "Installing Xcode Command Line Tools…"
    run "xcode-select --install || true"
    warn "If a dialog appeared, finish it, then re-run this script."
  fi
  ok "Xcode Command Line Tools present."
}

# ---------- 1) Homebrew ----------
ensure_homebrew(){
  if [ "$(id -u)" -eq 0 ]; then
    fail "Homebrew cannot be installed as root. Re-run as a normal user (no sudo)."
  fi
  if command -v brew >/dev/null 2>&1; then
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
  command -v brew >/dev/null 2>&1 || fail "Homebrew installation appears to have failed."

  Z="$HOME/.zprofile"
  [ -f "$Z" ] || : > "$Z"
  if ! grep -q 'Homebrew (added by sky130 installer)' "$Z" 2>/dev/null; then
    {
      echo ""
      echo "# Homebrew (added by sky130 installer)"
      if [ -x /opt/homebrew/bin/brew ]; then
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
      else
        echo 'eval "$(/usr/local/bin/brew shellenv)"'
      fi
    } >> "$Z"
  fi
  ok "Homebrew installed at $(brew --prefix)"
}

# ---------- 2) Brew deps ----------
install_brew_deps(){
  info "Installing build/runtime dependencies…"
  run "brew update"
  run "brew install git automake autoconf libtool pkg-config gawk wget xz tcl-tk ngspice cmake gnu-sed"
  run "brew install klayout || brew install --cask klayout || true"
  ok "Dependencies installed."
}

# ---------- 3) Magic (Cocoa Tk) ----------
build_magic_from_source(){
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

  # clean + update
  run "git fetch --all -q && git pull -q"
  run "make distclean || true"
  run "git clean -xfd -q || true"

  # Configure (Cocoa Tk; OpenGL off; Cairo on)
  run "./configure --prefix='$MAGIC_PREFIX' --with-x --with-opengl=no --disable-cairo ${TCLTK_PREFIX:+--with-tcl='$TCLTK_PREFIX/lib' --with-tk='$TCLTK_PREFIX/lib' --with-tclinclude='$TCLTK_PREFIX/include' --with-tkinclude='$TCLTK_PREFIX/include'}"

  # ==== IMPORTANT: avoid race on generated headers ====
  # Option A (safest for classrooms): full serial build
  run "make -j1"

  # Option B (faster): uncomment next 3 lines and comment out the serial line above.
  # First generate the header, then parallel build.
  # run "make -j1 database/database.h || true"
  # run "make -j${CORES}"
  # ================================================

  run "make install"

  PATH="$MAGIC_PREFIX/bin:$PATH"; export PATH
  command -v magic >/dev/null 2>&1 || fail "Magic built but not found in PATH."
  ok "Magic built and installed to $MAGIC_PREFIX."
}


# Force our Cocoa-Tk Magic to be the 'magic' command now & later
enforce_user_magic(){
  USER_MAGIC="$MAGIC_PREFIX/bin/magic"
  [ -x "$USER_MAGIC" ] || fail "Expected user-built magic at $USER_MAGIC (build failed?)"
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/magic" <<EOF
#!/bin/sh
exec "$USER_MAGIC" "\$@"
EOF
  chmod +x "$HOME/bin/magic"
  case ":$PATH:" in *":$HOME/bin:"*) : ;; *) PATH="$HOME/bin:$PATH"; export PATH ;; esac
  hash -r 2>/dev/null || true; rehash 2>/dev/null || true

  ensure_path_front(){
    rc="$1"; [ -f "$rc" ] || : > "$rc"
    if ! grep -q '### SKY130 installer: PATH front' "$rc" 2>/dev/null; then
      {
        echo ""
        echo "### SKY130 installer: PATH front"
        echo 'export PATH="$HOME/bin:$PATH"'
      } >> "$rc"
    fi
  }
  ensure_path_front "$HOME/.zprofile"
  ensure_path_front "$HOME/.zshrc"
  ensure_path_front "$HOME/.bash_profile"
  ensure_path_front "$HOME/.bashrc"

  WHICH_NOW="$(command -v magic 2>/dev/null || true)"
  if [ "$WHICH_NOW" = "$HOME/bin/magic" ]; then
    ok "magic now resolves to $WHICH_NOW (Cocoa Tk)."
  else
    warn "magic still resolves to $WHICH_NOW in this shell; shim installed at ~/bin/magic."
  fi
}

# ---------- 4) open_pdks (sky130A) ----------
build_open_pdks(){
  info "Building and installing open_pdks (sky130A)…"
  mkdir -p "$SRC_ROOT" "$PDK_PREFIX"
  cd "$SRC_ROOT"
  if [ ! -d open_pdks ]; then
    run "git clone https://github.com/RTimothyEdwards/open_pdks.git"
  fi
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

  PATH="$MAGIC_PREFIX/bin:$PATH"; export PATH  # Magic needed for tech gen
  run "./configure --prefix='$PDK_PREFIX' --enable-sky130-pdk --with-sky130-variants=A --disable-gf180mcu-pdk"
  run "make -j$CORES"
  run "make -j$CORES install"
  ok "open_pdks installed under $PDK_PREFIX"
}

# ---------- 5) Detect PDK_ROOT (parent that CONTAINS sky130A/) ----------
find_pdk_root(){
  cand="$PDK_ROOT_DEFAULT"
  if [ -f "$cand/sky130A/libs.tech/magic/sky130A.magicrc" ]; then printf '%s' "$cand"; return 0; fi

  info "Searching for installed sky130A…"
  found="$(find "$PDK_PREFIX" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || true)"

  if [ -z "$found" ]; then
    brew_share="$(brew --prefix 2>/dev/null || true)/share/pdk"
    [ -d "$brew_share" ] && found="$(find "$brew_share" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || true)"
  fi
  if [ -z "$found" ]; then
    for base in /opt/pdk/share/pdk /opt/share/pdk /opt/pdk /usr/local/share/pdk /opt/homebrew/share/pdk; do
      [ -d "$base" ] || continue
      found="$(find "$base" -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' -print -quit 2>/dev/null || true)"
      [ -n "$found" ] && break
    done
  fi
  if [ -n "$found" ]; then
    d1="$(dirname "$found")"; d2="$(dirname "$d1")"; d3="$(dirname "$d2")"; root="$(dirname "$d3")" # …/share/pdk
    printf '%s' "$root"; return 0
  fi
  return 1
}

# ---------- 6) Persist env (zsh: .zprofile + .zshrc) ----------
persist_env(){
  pdk_root="$1"
  write_block(){
    rc="$1"; [ -f "$rc" ] || : > "$rc"
    cp "$rc" "$rc.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    delete_block_in_file 'BEGIN SKY130 ENV' 'END SKY130 ENV' "$rc"
    cat >> "$rc" <<EOF

# ===== BEGIN SKY130 ENV (installed by sky130 installer) =====
export PDK_PREFIX="$PDK_PREFIX"
export PDK_ROOT="$pdk_root"
export SKYWATER_PDK="\$PDK_ROOT/sky130A"
export OPEN_PDKS_ROOT="\$PDK_PREFIX"
export MAGTYPE=mag
# Put our shims/tools first so 'magic' is the Cocoa build students run
export PATH="\$HOME/bin:$MAGIC_PREFIX/bin:\$PATH"
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
  }
  info "Persisting environment to ~/.zprofile and ~/.zshrc …"
  write_block "$HOME/.zprofile"
  write_block "$HOME/.zshrc"
  ok "Environment exports appended to zsh config files."
}

# ---------- 7) Write robust ~/.magicrc ----------
write_magic_rc(){
  info "Writing safe ~/.magicrc and removing stale wrappers…"
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

# ---------- 8) Optional helper ----------
install_magic_wrapper(){
  bin="$MAGIC_PREFIX/bin"
  mkdir -p "$bin"
  cat > "$bin/magic-sky130" <<'EOF'
#!/bin/sh
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

# ---------- 9) Verify + auto-fix SKY130 loading ----------
ensure_sky130_loaded_and_fix(){
  info "Verifying Magic loads SKY130A…"
  [ -x "$HOME/bin/magic" ] || warn "magic shim not present yet";  # enforce_user_magic should have created it
  MAGIC_CMD="$HOME/bin/magic"; [ -x "$MAGIC_CMD" ] || MAGIC_CMD="magic"

  FOUND_RC=""; PDK_ROOT_FIX=""
  CAND_ROOTS="
${PDK_ROOT-}
$PDK_PREFIX/share/pdk
$HOME/eda/pdks/share/pdk
$(command -v brew >/dev/null 2>&1 && brew --prefix 2>/dev/null)/share/pdk
/opt/pdk/share/pdk
/usr/local/share/pdk
/opt/homebrew/share/pdk
"
  for r in $CAND_ROOTS; do
    [ -n "$r" ] || continue
    [ -f "$r/sky130A/libs.tech/magic/sky130A.magicrc" ] || continue
    FOUND_RC="$r/sky130A/libs.tech/magic/sky130A.magicrc"; PDK_ROOT_FIX="$r"; break
  done
  if [ -z "$FOUND_RC" ]; then
    FOUND_RC="$(
      /usr/bin/find "$HOME" /opt /usr/local /opt/homebrew \
        -type f -path '*/sky130A/libs.tech/magic/sky130A.magicrc' \
        -print -quit 2>/dev/null || true
    )"
    if [ -n "$FOUND_RC" ]; then
      d1="$(dirname "$FOUND_RC")"; d2="$(dirname "$d1")"; d3="$(dirname "$d2")"; PDK_ROOT_FIX="$(dirname "$d3")"
    fi
  fi
  if [ -z "$FOUND_RC" ]; then
    warn "SKY130 PDK not found. Rebuilding open_pdks from source…"
    build_open_pdks
    if [ -f "$PDK_PREFIX/share/pdk/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
      FOUND_RC="$PDK_PREFIX/share/pdk/sky130A/libs.tech/magic/sky130A.magicrc"
      PDK_ROOT_FIX="$PDK_PREFIX/share/pdk"
    fi
  fi
  [ -n "$FOUND_RC" ] || fail "Could not locate sky130A.magicrc anywhere. open_pdks build likely failed."

  OUT="$(
    (PDK_ROOT="$PDK_ROOT_FIX" "$MAGIC_CMD" -noconsole -d null -rcfile "$FOUND_RC" <<'EOF'
tech
exit
EOF
    ) 2>&1 || true
  )"
  if echo "$OUT" | grep -qi 'sky130A'; then ok "Magic successfully loaded SKY130A."; return 0; fi

  warn "Magic did not report 'sky130A'. Auto-fixing env and rc…"
  write_magic_rc
  Z="$HOME/.zprofile"; [ -f "$Z" ] || : > "$Z"; cp "$Z" "$Z.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  delete_block_in_file 'BEGIN SKY130 ENV' 'END SKY130 ENV' "$Z"
  {
    echo ""; echo "# ===== BEGIN SKY130 ENV (installed by sky130 installer) ====="
    echo "export PDK_PREFIX=\"$PDK_PREFIX\""
    echo "export PDK_ROOT=\"$PDK_ROOT_FIX\""
    echo "export SKYWATER_PDK=\"\$PDK_ROOT/sky130A\""
    echo "export OPEN_PDKS_ROOT=\"\$PDK_PREFIX\""
    echo "export MAGTYPE=mag"
    echo "export PATH=\"\$HOME/bin:$MAGIC_PREFIX/bin:\$PATH\""
    echo 'if command -v brew >/dev/null 2>&1; then'
    echo '  BREW_TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || true)"'
    echo '  if [ -n "$BREW_TCLTK_PREFIX" ]; then'
    echo '    export LDFLAGS="-L$BREW_TCLTK_PREFIX/lib${LDFLAGS:+ $LDFLAGS}"'
    echo '    export CPPFLAGS="-I$BREW_TCLTK_PREFIX/include${CPPFLAGS:+ $CPPFLAGS}"'
    echo '    export PKG_CONFIG_PATH="$BREW_TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"'
    echo '  fi'
    echo 'fi'
    echo "# ===== END SKY130 ENV ====="
  } >> "$Z"
  # also mirror to .zshrc
  delete_block_in_file 'BEGIN SKY130 ENV' 'END SKY130 ENV' "$HOME/.zshrc" || true
  cat >> "$HOME/.zshrc" <<EOF

# ===== BEGIN SKY130 ENV (installed by sky130 installer) =====
export PDK_PREFIX="$PDK_PREFIX"
export PDK_ROOT="$PDK_ROOT_FIX"
export SKYWATER_PDK="\$PDK_ROOT/sky130A"
export OPEN_PDKS_ROOT="\$PDK_PREFIX"
export MAGTYPE=mag
export PATH="\$HOME/bin:$MAGIC_PREFIX/bin:\$PATH"
# ===== END SKY130 ENV =====
EOF

  OUT="$(
    (PDK_ROOT="$PDK_ROOT_FIX" "$MAGIC_CMD" -noconsole -d null -rcfile "$FOUND_RC" <<'EOF'
tech
exit
EOF
    ) 2>&1 || true
  )"
  echo "$OUT" | grep -qi 'sky130A' && ok "Re-test succeeded — SKY130A is now loading." || warn "Re-test did not report 'sky130A'. Output was:\n$OUT"
}

# ---------- 10) Smoke test ----------
smoke_test(){
  pdk_root="$1"
  rc="$pdk_root/sky130A/libs.tech/magic/sky130A.magicrc"
  info "Running headless Magic smoke test (via PDK rc)…"
  [ -f "$rc" ] || fail "Missing $rc (open_pdks install incomplete?)"
  MAGIC_CMD="$HOME/bin/magic"; [ -x "$MAGIC_CMD" ] || MAGIC_CMD="magic"
  out="$(
    (PDK_ROOT="$pdk_root" "$MAGIC_CMD" -noconsole -d null -rcfile "$rc" <<'EOF'
tech
exit
EOF
    ) 2>&1 || true
  )"
  echo "$out" | grep -qi 'sky130A' && ok "Magic successfully loaded sky130A." || { warn "Magic did not report 'sky130A'. Output was:\n$out"; }
}

main(){
  ensure_xcode
  ensure_homebrew
  install_brew_deps
  build_magic_from_source
  enforce_user_magic               # ensure 'magic' is our Cocoa build
  build_open_pdks

  if ! PDK_ROOT_FOUND="$(find_pdk_root)"; then
    fail "Could not locate installed sky130A. Check build logs above."
  fi
  ok "Detected PDK_ROOT: $PDK_ROOT_FOUND"

  persist_env "$PDK_ROOT_FOUND"
  write_magic_rc
  install_magic_wrapper
  ensure_sky130_loaded_and_fix
  smoke_test "$PDK_ROOT_FOUND"

  cat <<EOF
Next steps:
  • You can now launch Magic normally:
      magic &
  • In Magic console:  :tech   (should print "sky130A")
  • If a shell still doesn’t see 'magic', run:
      exec \$SHELL -l
EOF
  ok "All set!"
}

main "$@"
