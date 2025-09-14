#!/usr/bin/env bash
# sky130-magic-only.sh — Magic + XQuartz + Sky130 PDK (MacPorts) with robust sanity checks
# Launchers after install:
#   magic-sky130           # Magic (GUI via XQuartz)
#   magic-sky130 --safe    # Magic (headless)

set -uo pipefail

MACPORTS_PREFIX="/opt/local"
PDK_PREFIX="/opt/pdk"
WORKDIR="${HOME}/.eda-bootstrap"
DEMO_DIR="${HOME}/sky130-demo"
RC_DIR="${HOME}/.config/sky130"

PASS=()
FAIL=()

say()  { printf "\033[1;36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "✔ $*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "⚠ $*"; }
err()  { printf "\033[1;31m%s\033[0m\n" "✖ $*"; }

mark_pass(){ PASS+=("$1"); ok "$1"; }
mark_fail(){ FAIL+=("$1 — $2"); err "$1 — $2"; }

ensure_dir() {
  # ensure_dir <path> [sudo]
  local d="$1"; local need_sudo="${2:-}"
  if [[ -n "$need_sudo" ]]; then
    sudo install -d -m 755 "$d"
  else
    install -d -m 755 "$d"
  fi
}

need_xcode() {
  say "Checking Xcode Command Line Tools…"
  if xcode-select -p >/dev/null 2>&1; then
    mark_pass "Xcode Command Line Tools present"
  else
    say "Prompting install of Command Line Tools…"
    xcode-select --install || true
    if xcode-select -p >/dev/null 2>&1; then
      mark_pass "Xcode Command Line Tools installed"
    else
      mark_fail "Xcode Command Line Tools" "Not installed. Accept Apple's installer dialog, then re-run."
    fi
  fi
}

fix_macports_signing() {
  say "Applying MacPorts signing/quarantine fix (Sequoia)…"
  sudo xattr -dr com.apple.quarantine /opt/local 2>/dev/null || true
  while IFS= read -r -d '' f; do sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true; done < <(/usr/bin/find /opt/local -type f \( -name 'tclsh*' -o -name '*.dylib' \) -print0)
}

macports_ok() {
  /usr/bin/env -i PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" "$MACPORTS_PREFIX/bin/port" version >/dev/null 2>&1
}

reinstall_macports_source() {
  say "Installing MacPorts from source (bulletproof)…"
  sudo rm -rf /opt/local /Applications/MacPorts /Library/Tcl/macports1.0 /Library/LaunchDaemons/org.macports.* 2>/dev/null || true
  local ver="2.10.4"
  ensure_dir "$WORKDIR"; cd "$WORKDIR"
  curl -fL "https://distfiles.macports.org/MacPorts/MacPorts-$ver.tar.bz2" -o "MacPorts-$ver.tar.bz2" || return 1
  tar xf "MacPorts-$ver.tar.bz2" || return 1
  cd "MacPorts-$ver" || return 1
  ./configure --prefix=/opt/local && make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" && sudo make install || return 1
  return 0
}

ensure_macports() {
  say "Ensuring MacPorts…"
  if command -v port >/dev/null 2>&1; then
    if macports_ok; then
      sudo port -v selfupdate >/dev/null 2>&1 || true
      mark_pass "MacPorts CLI ready"
      return
    fi
    fix_macports_signing
    if macports_ok; then
      mark_pass "MacPorts (post-signing-fix) ready"
      return
    fi
    if reinstall_macports_source && macports_ok; then
      mark_pass "MacPorts (rebuilt from source)"
      return
    fi
    mark_fail "MacPorts" "port not usable even after source rebuild"
    return
  fi

  # Install via .pkg (then fix if needed)
  ensure_dir "$WORKDIR"; cd "$WORKDIR"
  local swmaj; swmaj="$(sw_vers -productVersion | awk -F. '{print $1}')"
  local PKG=""
  case "$swmaj" in
    15) PKG="MacPorts-2.10.4-15-Sequoia.pkg" ;;
    14) PKG="MacPorts-2.10.4-14-Sonoma.pkg"  ;;
    13) PKG="MacPorts-2.10.4-13-Ventura.pkg" ;;
    12) PKG="MacPorts-2.10.4-12-Monterey.pkg";;
    *)  mark_fail "MacPorts" "Unsupported macOS $(sw_vers -productVersion)"; return ;;
  esac
  say "Installing MacPorts (${PKG})…"
  if curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/${PKG}" -o "$PKG" && sudo installer -pkg "$PKG" -target /; then
    if sudo /opt/local/bin/port -v selfupdate >/dev/null 2>&1; then
      mark_pass "MacPorts installed"
    else
      fix_macports_signing
      if sudo /opt/local/bin/port -v selfupdate >/dev/null 2>&1; then
        mark_pass "MacPorts installed (post-signing-fix)"
      else
        if reinstall_macports_source && macports_ok; then
          mark_pass "MacPorts (rebuilt from source)"
        else
          mark_fail "MacPorts" "Selfupdate failed; source rebuild also failed"
        fi
      fi
    fi
  else
    mark_fail "MacPorts" "Failed to download/install pkg"
  fi
}

ensure_xquartz() {
  say "Ensuring XQuartz…"
  if [[ -d "/Applications/XQuartz.app" || -d "/Applications/Utilities/XQuartz.app" ]]; then
    mark_pass "XQuartz app present"
    return
  fi
  ensure_dir "$WORKDIR"; cd "$WORKDIR"
  local PKG_URL=""
  if curl -fsSL "https://api.github.com/repos/XQuartz/XQuartz/releases/latest" -o xq.json; then
    PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json)"
  fi
  if [[ -z "$PKG_URL" ]]; then
    mark_fail "XQuartz" "Could not auto-detect pkg URL"
    return
  fi
  if curl -fL "$PKG_URL" -o XQuartz.pkg && sudo installer -pkg XQuartz.pkg -target /; then
    mark_pass "XQuartz installed"
  else
    mark_fail "XQuartz" "Installer failed"
  fi
}

ports_install_magic() {
  say "Installing Magic (+x11) via MacPorts…"
  local ok_all=true
  sudo port -N upgrade --enforce-variants tk +x11 >/dev/null 2>&1 || sudo port -N install tk +x11 >/dev/null 2>&1 || ok_all=false
  sudo port -N upgrade --enforce-variants magic +x11 -quartz >/dev/null 2>&1 || sudo port -N install magic +x11 >/dev/null 2>&1 || ok_all=false
  # Optional helpers
  sudo port -N install ngspice netgen >/dev/null 2>&1 || true
  if $ok_all && [[ -x /opt/local/bin/magic ]]; then
    mark_pass "Magic installed"
  else
    mark_fail "Magic" "MacPorts install failed"
  fi
}

install_pdk() {
  say "Installing Sky130 PDK (open_pdks)…"
  ensure_dir "$PDK_PREFIX" sudo
  sudo chown "$(id -u)":"$(id -g)" "$PDK_PREFIX" || true
  ensure_dir "$WORKDIR"; cd "$WORKDIR"
  if [[ -d open_pdks/.git ]]; then
    (cd open_pdks && git pull --rebase >/dev/null 2>&1)
  else
    git clone https://github.com/RTimothyEdwards/open_pdks.git >/dev/null 2>&1 || { mark_fail "Sky130 PDK" "git clone failed"; return; }
  fi
  cd open_pdks || { mark_fail "Sky130 PDK" "open_pdks dir missing"; return; }
  if ./configure --prefix="$PDK_PREFIX" --enable-sky130-pdk --with-sky130-local-path="$PDK_PREFIX" --enable-sram-sky130 >/dev/null 2>&1 \
     && make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null 2>&1 \
     && sudo make install >/dev/null 2>&1; then
    :
  else
    mark_fail "Sky130 PDK" "open_pdks build/install failed"
    return
  fi

  # Detect A or B and presence of magic rc
  local found=""
  for base in "$PDK_PREFIX" "$PDK_PREFIX/share/pdk"; do
    for name in sky130A sky130B; do
      if [[ -f "$base/$name/libs.tech/magic/${name}.magicrc" ]]; then
        found="$base/$name"
        break
      fi
    done
    [[ -n "$found" ]] && break
  done

  if [[ -n "$found" ]]; then
    mark_pass "Sky130 PDK installed ($(basename "$found"))"
  else
    mark_fail "Sky130 PDK" "No sky130A/B with magicrc found under $PDK_PREFIX"
  fi
}

write_demo() {
  say "Writing demo files…"
  ensure_dir "$DEMO_DIR"
  cat > "$DEMO_DIR/inverter_tt.spice" <<'EOF'
.option nomod
.option scale=1e-6
.lib $PDK_ROOT/${PDK}/libs.tech/ngspice/sky130.lib.spice tt
VDD vdd 0 1.8
VIN in  0 PULSE(0 1.8 0n 100p 100p 5n 10n)
CL  out 0 10f
M1 out in 0  0  sky130_fd_pr__nfet_01v8 W=1.0 L=0.15
M2 out in vdd vdd sky130_fd_pr__pfet_01v8 W=2.0 L=0.15
.control
tran 0.1n 50n
plot v(in) v(out)
.endc
.end
EOF
  cat > "$DEMO_DIR/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
  mark_pass "Demo files created"
}

write_rc_wrapper() {
  say "Writing Magic rc wrapper…"
  ensure_dir "$RC_DIR"
  cat > "$RC_DIR/rc_wrapper.tcl" <<'EOF'
if {![info exists env(PDK_ROOT)]} { set env(PDK_ROOT) "/opt/pdk" }
if {![info exists env(PDK)]}      { set env(PDK)      "sky130A" }
source "$env(PDK_ROOT)/$env(PDK)/libs.tech/magic/${env(PDK)}.magicrc"

namespace eval ::sky130 { variable tries 0; variable targetGeom "1400x900+80+60" }
proc ::sky130::apply_geometry {} {
    variable tries; variable targetGeom
    catch { wm attributes . -zoomed 0 }
    catch { wm attributes . -fullscreen 0 }
    wm geometry . $targetGeom
    set sw [winfo screenwidth .]; set sh [winfo screenheight .]
    catch { wm maxsize . [expr {$sw-120}] [expr {$sh-120}] }
    if {$tries < 1} { puts ">>> rc_wrapper.tcl: geometry $targetGeom (screen=${sw}x${sh})" }
    incr tries
    if {$tries < 3} { after 600 ::sky130::apply_geometry }
}
after 120 ::sky130::apply_geometry
bind . <Map>        { after 100 ::sky130::apply_geometry }
bind . <Visibility> { after 150 ::sky130::apply_geometry }
after 200 {
  catch { wm title . "Magic ($env(PDK)) — SKY130 Classroom" }
  catch { if {[winfo exists .console]} { wm geometry .console "+40+40" } }
}
EOF
  mark_pass "Magic rc wrapper created"
}

install_magic_launcher() {
  say "Installing Magic launcher…"
  local target_dir="/usr/local/bin"
  if ! sudo install -d -m 755 "$target_dir" 2>/dev/null; then
    warn "Could not create $target_dir; falling back to /opt/local/bin."
    target_dir="/opt/local/bin"
    sudo install -d -m 755 "$target_dir"
  fi
  local target="$target_dir/magic-sky130"

  if sudo tee "$target" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk; do for n in sky130A sky130B; do [[ -d "$b/$n" ]]&&{ echo "$b" "$n"; return 0; }; done; done; return 1; }
read -r PDK_ROOT PDK < <(choose_pdk) || { echo "No SKY130 PDK found."; exit 1; }
export PDK_ROOT PDK
MAGIC_BIN="/opt/local/bin/magic"
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [[ -f "$RC_WRAPPER" ]] && RC="$RC_WRAPPER"
pgrep -f XQuartz >/dev/null 2>&1 || { open -a XQuartz || true; sleep 3; }
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && LDISP="$d/org.xquartz:0" && break
  done
fi
export DISPLAY="${LDISP:-:0}"
CLEAN_ENV=(/usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK")
echo ">>> magic-sky130 launcher: using RC=$RC"
if [[ "${1:-}" == "--safe" ]]; then
  exec "${CLEAN_ENV[@]}" "$MAGIC_BIN" -norcfile -dnull -noconsole -T "$PDK" -rcfile "$RC" "${@:2}"
fi
exec "${CLEAN_ENV[@]}" "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
  then
    sudo chmod +x "$target"
    # Convenience symlink if we fell back to /opt/local/bin
    if [[ "$target" = "/opt/local/bin/magic-sky130" && -d /usr/local/bin ]]; then
      sudo ln -sf "$target" /usr/local/bin/magic-sky130 || true
    fi
    mark_pass "Magic launcher installed at $target"
  else
    mark_fail "Magic launcher" "Could not write launcher"
  fi
}

headless_check() {
  say "Running headless Magic tech check…"
  # Find PDK
  local PDK_BASE="" PDK_NAME=""
  for base in "$PDK_PREFIX" "$PDK_PREFIX/share/pdk"; do
    for name in sky130A sky130B; do
      if [[ -f "$base/$name/libs.tech/magic/${name}.magicrc" ]]; then
        PDK_BASE="$base"; PDK_NAME="$name"; break
      fi
    done
    [[ -n "$PDK_NAME" ]] && break
  done
  if [[ -z "$PDK_NAME" ]]; then
    mark_fail "Magic tech check" "Sky130 PDK not found"
    return
  fi

  ensure_dir "$DEMO_DIR"
  cat > "$DEMO_DIR/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF

  /usr/bin/env -i \
    PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$HOME" PDK_ROOT="$PDK_BASE" PDK="$PDK_NAME" \
    /opt/local/bin/magic -norcfile -dnull -noconsole -T "$PDK_NAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$DEMO_DIR/smoke.tcl" \
    >"$WORKDIR/magic_headless.log" 2>&1

  if grep -q ">>> smoke: tech=" "$WORKDIR/magic_headless.log" 2>/dev/null; then
    mark_pass "Magic headless tech load"
  else
    mark_fail "Magic headless tech load" "See $WORKDIR/magic_headless.log"
  fi
}

summary() {
  echo
  say "==== INSTALL SUMMARY ===="
  if ((${#PASS[@]})); then
    ok "Passed:"
    for p in "${PASS[@]}"; do echo "  • $p"; done
  fi
  if ((${#FAIL[@]})); then
    err "Failed:"
    for f in "${FAIL[@]}"; do echo "  • $f"; done
    echo
    err "One or more checks failed. Review messages above."
    exit 1
  else
    ok "All checks passed."
    echo
    echo "Run:"
    echo "  • magic-sky130           (GUI)"
    echo "  • magic-sky130 --safe    (headless)"
    echo
    echo "Demo:"
    echo "  • cd \"$DEMO_DIR\" && ngspice inverter_tt.spice"
    exit 0
  fi
}

main() {
  # Create user-level dirs up front
  ensure_dir "$WORKDIR"
  ensure_dir "$RC_DIR"
  ensure_dir "$DEMO_DIR"

  need_xcode
  ensure_macports
  ensure_xquartz
  ports_install_magic
  install_pdk
  write_demo
  write_rc_wrapper
  install_magic_launcher
  headless_check
  summary
}

main "$@"
