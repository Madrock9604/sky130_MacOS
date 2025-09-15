#!/usr/bin/env bash
# sky130-magic-only.sh — Magic + XQuartz + Sky130 PDK with robust checks & auto-repair (macOS)
# Launchers after install:
#   magic-sky130           # Magic GUI (via XQuartz, window sized sanely)
#   magic-sky130 --safe    # Magic headless (no GUI)

set -uo pipefail

# --- constants/dirs ---------------------------------------------------------
MACPORTS_PREFIX="/opt/local"
PDK_PREFIX="/opt/pdk"
WORKDIR="${HOME}/.eda-bootstrap"
DEMO_DIR="${HOME}/sky130-demo"
RC_DIR="${HOME}/.config/sky130"
HEADLESS_LOG="${WORKDIR}/magic_headless.log"

PASS=()
FAIL=()

# --- pretty printers ---------------------------------------------------------
say()  { printf "\033[1;36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "✔ $*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "⚠ $*"; }
err()  { printf "\033[1;31m%s\033[0m\n" "✖ $*"; }

mark_pass(){ PASS+=("$1"); ok "$1"; }
mark_fail(){ FAIL+=("$1 — $2"); err "$1 — $2"; }

# --- helpers -----------------------------------------------------------------
ensure_dir() {
  # ensure_dir <path> [sudo]
  local d="$1"; local need_sudo="${2:-}"
  if [[ -n "$need_sudo" ]]; then
    sudo install -d -m 755 "$d"
  else
    install -d -m 755 "$d"
  fi
}

ensure_path_now(){ export PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"; }

# Presence detectors
magic_path(){
  if [[ -x /opt/local/bin/magic ]]; then echo /opt/local/bin/magic; return 0; fi
  if [[ -x /usr/local/bin/magic ]]; then echo /usr/local/bin/magic; return 0; fi
  return 1
}

pdk_loc(){
  for base in "/opt/pdk" "/opt/pdk/share/pdk" "/usr/local/share/pdk"; do
    for name in sky130A sky130B; do
      if [[ -f "$base/$name/libs.tech/magic/${name}.magicrc" ]]; then
        echo "$base $name"; return 0
      fi
    done
  done
  return 1
}

# --- XQuartz helpers/repair --------------------------------------------------
xquartz_display_value(){
  local ld; ld="$(launchctl getenv DISPLAY || true)"
  if [[ -n "$ld" ]]; then echo "$ld"; return 0; fi
  for d in /private/tmp/com.apple.launchd.*; do
    [[ -S "$d/org.xquartz:0" ]] && { echo "$d/org.xquartz:0"; return 0; }
  done
  echo ":0"
}

xquartz_sanity(){
  # Start XQuartz, set DISPLAY, test xset -q. Returns 0 on success.
  pgrep -x XQuartz >/dev/null || { open -ga XQuartz || true; sleep 4; }
  local disp; disp="$(xquartz_display_value)"
  export DISPLAY="$disp"
  launchctl setenv DISPLAY "$disp" >/dev/null 2>&1 || true
  /opt/X11/bin/xhost +SI:localuser:$USER >/dev/null 2>&1 || true
  /opt/X11/bin/xset -q >/dev/null 2>&1
}

repair_xquartz(){
  say "Repairing XQuartz (reset prefs, reinstall, de-quarantine)…"
  pkill -x XQuartz 2>/dev/null || true
  sleep 1
  defaults delete org.xquartz.X11  >/dev/null 2>&1 || true
  rm -f  "$HOME/Library/Preferences/org.xquartz.X11.plist"        || true
  rm -rf "$HOME/Library/Caches/org.xquartz.X11"                    || true
  rm -f  "$HOME/.Xauthority" "$HOME/.serverauth."*                 || true

  if command -v brew >/dev/null 2>&1; then
    brew uninstall --cask xquartz >/dev/null 2>&1 || true
    brew install   --cask xquartz
  else
    ensure_dir "$WORKDIR"; cd "$WORKDIR" || return 1
    curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest -o xq.json || return 1
    local pkg; pkg="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json || true)"
    [[ -n "$pkg" ]] || return 1
    curl -fL "$pkg" -o XQuartz.pkg || return 1
    sudo installer -pkg XQuartz.pkg -target / || return 1
  fi

  sudo xattr -dr com.apple.quarantine /Applications/XQuartz.app /opt/X11 || true
  xquartz_sanity
}

# --- Tk/Wish sanity + repair -------------------------------------------------
tk_wish_sanity() {
  # Ensure XQuartz is up and DISPLAY works
  pgrep -x XQuartz >/dev/null || { open -ga XQuartz || true; sleep 4; }
  local disp; disp="$(xquartz_display_value)"
  export DISPLAY="$disp"
  launchctl setenv DISPLAY "$disp" >/dev/null 2>&1 || true
  /opt/X11/bin/xhost +SI:localuser:$USER >/dev/null 2>&1 || true

  # Pick Wish from MacPorts
  local WISH="/opt/local/bin/wish8.6"
  [[ -x "$WISH" ]] || WISH="/opt/local/bin/wish8.7"
  [[ -x "$WISH" ]] || return 1

  # Minimal Tk script: show a tiny window briefly, then exit 0
  ensure_dir "$WORKDIR"
  cat > "$WORKDIR/tk_test.tcl" <<'TCL'
package require Tk
wm geometry . 200x80+120+120
label .l -text "Tk/X11 OK"; pack .l
after 400 { exit 0 }
vwait forever
TCL

  "$WISH" "$WORKDIR/tk_test.tcl" >/dev/null 2>&1
}

repair_tk_wish() {
  say "Repairing Tk/Wish (force +x11, re-sign libs)…"
  local line
  line="$(/opt/local/bin/port -qv installed tk 2>/dev/null | awk '/active/{print}')"
  if [[ "$line" != *"+x11"* ]]; then
    sudo /opt/local/bin/port -N -f uninstall tk || true
    sudo /opt/local/bin/port -N install tk +x11
  else
    sudo /opt/local/bin/port -N upgrade --enforce-variants tk +x11 || sudo /opt/local/bin/port -N install tk +x11
  fi

  # Re-sign Tcl/Tk bits to dodge Sequoia TeamID mismatch
  sudo xattr -dr com.apple.quarantine /opt/local || true
  while IFS= read -r -d '' f; do
    sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true
  done < <(/usr/bin/find /opt/local -type f \( -name 'libtcl*.dylib' -o -name 'libtk*.dylib' -o -name 'tclsh*' -o -name 'wish*' \) -print0)

  sudo /opt/local/bin/port -N rev-upgrade >/dev/null 2>&1 || true
}

# --- checks & installers -----------------------------------------------------
need_xcode() {
  say "Checking Xcode Command Line Tools…"
  if xcode-select -p >/dev/null 2>&1; then
    mark_pass "Xcode Command Line Tools present"
  else
    say "Prompting install of Command Line Tools… (accept Apple dialog)"
    xcode-select --install || true
    if xcode-select -p >/dev/null 2>&1; then
      mark_pass "Xcode Command Line Tools installed"
    else
      mark_fail "Xcode Command Line Tools" "Not installed. Finish Apple installer, then re-run."
    fi
  fi
}

fix_macports_signing() {
  say "Applying MacPorts signing/quarantine fix (Sequoia)…"
  sudo xattr -dr com.apple.quarantine /opt/local 2>/dev/null || true
  while IFS= read -r -d '' f; do
    sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true
  done < <(/usr/bin/find /opt/local -type f \( -name 'tclsh*' -o -name '*.dylib' \) -print0)
}

macports_ok() {
  /usr/bin/env -i PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" "$MACPORTS_PREFIX/bin/port" version >/dev/null 2>&1
}

reinstall_macports_source() {
  say "Installing MacPorts from source (bulletproof)…"
  sudo rm -rf /opt/local /Applications/MacPorts /Library/Tcl/macports1.0 /Library/LaunchDaemons/org.macports.* 2>/dev/null || true
  local ver="2.10.4"
  ensure_dir "$WORKDIR"; cd "$WORKDIR" || exit 1
  curl -fL "https://distfiles.macports.org/MacPorts/MacPorts-$ver.tar.bz2" -o "MacPorts-$ver.tar.bz2" || return 1
  tar xf "MacPorts-$ver.tar.bz2" || return 1
  cd "MacPorts-$ver" || return 1
  ./configure --prefix=/opt/local && make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" && sudo make install || return 1
  return 0
}

ensure_macports() {
  say "Ensuring MacPorts…"
  ensure_path_now
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
  ensure_dir "$WORKDIR"; cd "$WORKDIR" || exit 1
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
    ensure_path_now
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
  local have=false
  if [[ -d "/Applications/XQuartz.app" || -d "/Applications/Utilities/XQuartz.app" ]]; then
    have=true
  else
    ensure_dir "$WORKDIR"; cd "$WORKDIR" || exit 1
    local PKG_URL=""
    if curl -fsSL "https://api.github.com/repos/XQuartz/XQuartz/releases/latest" -o xq.json; then
      PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json)"
    fi
    if [[ -n "$PKG_URL" ]] && curl -fL "$PKG_URL" -o XQuartz.pkg && sudo installer -pkg XQuartz.pkg -target /; then
      have=true
    fi
  fi

  if ! $have; then
    mark_fail "XQuartz" "App not installed"; return
  fi

  # Try a quick GUI sanity check; if it fails, do a repair pass once.
  if xquartz_sanity; then
    mark_pass "XQuartz running (DISPLAY=$(xquartz_display_value))"
  else
    warn "XQuartz sanity check failed; attempting repair…"
    if repair_xquartz && xquartz_sanity; then
      mark_pass "XQuartz repaired and running"
    else
      mark_fail "XQuartz" "Repair failed; GUI may crash"
    fi
  fi
}

ports_install_magic() {
  say "Checking Magic…"
  if MAGIC_BIN="$(magic_path)"; then
    mark_pass "Magic present at ${MAGIC_BIN}"
    return
  fi

  say "Installing Magic via MacPorts (+x11)…"
  local ok_all=true
  sudo port -N upgrade --enforce-variants tk +x11 >/dev/null 2>&1 || sudo port -N install tk +x11 >/dev/null 2>&1 || ok_all=false
  sudo port -N upgrade --enforce-variants magic +x11 -quartz >/dev/null 2>&1 || sudo port -N install magic +x11 >/dev/null 2>&1 || ok_all=false
  sudo port -N install ngspice netgen >/dev/null 2>&1 || true

  if MAGIC_BIN="$(magic_path)"; then
    mark_pass "Magic installed at ${MAGIC_BIN}"
  else
    mark_fail "Magic" "MacPorts install failed"
  fi
}

install_pdk() {
  say "Checking Sky130 PDK…"
  if read -r PDK_BASE PDK_NAME < <(pdk_loc); then
    mark_pass "Sky130 PDK present at ${PDK_BASE}/${PDK_NAME}"
    return
  fi

  say "Installing Sky130 PDK via open_pdks…"
  ensure_dir "$PDK_PREFIX" sudo
  sudo chown "$(id -u)":"$(id -g)" "$PDK_PREFIX" || true
  ensure_dir "$WORKDIR"; cd "$WORKDIR" || exit 1

  if [[ -d open_pdks/.git ]]; then
    (cd open_pdks && git pull --rebase >/dev/null 2>&1)
  else
    git clone https://github.com/RTimothyEdwards/open_pdks.git >/dev/null 2>&1 || {
      mark_fail "Sky130 PDK" "git clone failed"; return; }
  fi

  cd open_pdks || { mark_fail "Sky130 PDK" "open_pdks dir missing"; return; }

  # helpful deps (ignore errors if already present)
  sudo port -N install git gawk wget tcl tk >/dev/null 2>&1 || true

  if ./configure --prefix="$PDK_PREFIX" --enable-sky130-pdk --with-sky130-local-path="$PDK_PREFIX" --enable-sram-sky130 >/dev/null 2>&1 \
     && make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null 2>&1 \
     && sudo make install >/dev/null 2>&1; then
    :
  fi

  # Final detection (pass if present, even if build printed warnings)
  if read -r PDK_BASE PDK_NAME < <(pdk_loc); then
    mark_pass "Sky130 PDK installed at ${PDK_BASE}/${PDK_NAME}"
  else
    mark_fail "Sky130 PDK" "open_pdks build/install failed; no sky130A/B found under /opt or /usr/local"
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

  # Prefer /usr/local/bin; fall back to /opt/local/bin if needed.
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
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do for n in sky130A sky130B; do [[ -d "$b/$n" ]]&&{ echo "$b" "$n"; return 0; }; done; done; return 1; }
read -r PDK_ROOT PDK < <(choose_pdk) || { echo "No SKY130 PDK found."; exit 1; }
export PDK_ROOT PDK
MAGIC_BIN="/opt/local/bin/magic"
[[ -x "$MAGIC_BIN" ]] || MAGIC_BIN="/usr/local/bin/magic"
[[ -x "$MAGIC_BIN" ]] || { echo "magic binary not found."; exit 1; }
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [[ -f "$RC_WRAPPER" ]] && RC="$RC_WRAPPER"
# Ensure XQuartz is up and DISPLAY is set
pgrep -f XQuartz >/dev/null 2>&1 || { open -a XQuartz || true; sleep 3; }
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && LDISP="$d/org.xquartz:0" && break
  done
fi
export DISPLAY="${LDISP:-:0}"
CLEAN_ENV=(/usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK")
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
  if ! MAGIC_BIN="$(magic_path)"; then
    mark_fail "Magic tech check" "magic binary not found"; return
  fi
  if ! read -r PDK_BASE PDK_NAME < <(pdk_loc); then
    mark_fail "Magic tech check" "Sky130 PDK not found"; return
  fi
  ensure_dir "$DEMO_DIR"
  cat > "$DEMO_DIR/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
  /usr/bin/env -i \
    PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$HOME" PDK_ROOT="$PDK_BASE" PDK="$PDK_NAME" \
    "$MAGIC_BIN" -norcfile -dnull -noconsole -T "$PDK_NAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$DEMO_DIR/smoke.tcl" \
    >"$HEADLESS_LOG" 2>&1 || true
  if grep -q ">>> smoke: tech=" "$HEADLESS_LOG" 2>/dev/null; then
    mark_pass "Magic headless tech load"
  else
    mark_fail "Magic headless tech load" "See $HEADLESS_LOG"
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
  ensure_path_now
  ensure_xquartz

  # Verify Tk/Wish; auto-repair once if it fails (prevents “wish quit unexpectedly”)
  if tk_wish_sanity; then
    mark_pass "Tk/Wish GUI sanity"
  else
    warn "Tk/Wish sanity failed; attempting repair…"
    repair_tk_wish
    if tk_wish_sanity; then
      mark_pass "Tk/Wish repaired"
    else
      mark_fail "Tk/Wish" "Wish still crashing; see MacPorts tk and XQuartz"
    fi
  fi

  ports_install_magic
  install_pdk
  write_demo
  write_rc_wrapper
  install_magic_launcher
  headless_check
  summary
}

main "$@"
