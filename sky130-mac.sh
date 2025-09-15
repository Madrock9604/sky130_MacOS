#!/bin/sh
# sky130-mac.sh — Magic + SKY130 PDK (macOS) with robust checks, auto-repair, and dual fallbacks.
# Launchers after install:
#   magic-sky130           # normal GUI
#   magic-sky130-xsafe     # GUI with software GL (for crashy GPUs)
#   magic-sky130-nogl      # GUI using a no-OpenGL Magic build (built only if needed)
set -eu

say()  { printf '%s\n' "$*"; }
ok()   { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
err()  { printf 'ERROR: %s\n' "$*"; }

MACPORTS_PREFIX="/opt/local"
PDK_PREFIX="/opt/pdk"
WORKDIR="$HOME/.eda-bootstrap"
LOGDIR="$WORKDIR/logs"
DEMO_DIR="$HOME/sky130-demo"
RC_DIR="$HOME/.config/sky130"
SRC_NOG="$WORKDIR/magic-nogl"
MAGIC_VER="${MAGIC_VER:-8.3.551}"
MAGIC_URL="https://github.com/RTimothyEdwards/magic/archive/refs/tags/$MAGIC_VER.tar.gz"
PASS=""
FAIL=""

ensure_dir() { # ensure_dir <path> [sudo]
  if [ "${2-}" = "sudo" ]; then sudo install -d -m 755 "$1"; else install -d -m 755 "$1"; fi
}
ensure_path() {
  PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
  export PATH
}
mark_pass(){ PASS="${PASS}  • $1\n"; ok "$1"; }
mark_fail(){ FAIL="${FAIL}  • $1 — $2\n"; err "$1 — $2"; }

magic_path() {
  [ -x /opt/local/bin/magic ] && { printf '/opt/local/bin/magic\n'; return; }
  [ -x /usr/local/bin/magic ] && { printf '/usr/local/bin/magic\n'; return; }
  printf '\n'
}
pdk_loc() {
  for base in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
    for name in sky130A sky130B; do
      if [ -f "$base/$name/libs.tech/magic/${name}.magicrc" ]; then
        printf '%s %s\n' "$base" "$name"; return 0
      fi
    done
  done
  return 1
}

xquartz_display() {
  LD="$(launchctl getenv DISPLAY 2>/dev/null || true)"
  if [ -n "${LD:-}" ]; then printf '%s\n' "$LD"; return; fi
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && { printf '%s\n' "$d/org.xquartz:0"; return; }
  done
  printf '%s\n' ":0"
}
xquartz_sanity() {
  pgrep -x XQuartz >/dev/null 2>&1 || { 
    if [ -d "/Applications/XQuartz.app" ] || [ -d "/Applications/Utilities/XQuartz.app" ]; then
      open -ga XQuartz || true; sleep 4
    else
      err "XQuartz missing. Install with: brew install --cask xquartz"; return 1
    fi
  }
  DISP="$(xquartz_display)"; export DISPLAY="$DISP"
  launchctl setenv DISPLAY "$DISP" >/dev/null 2>&1 || true
  /opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
  /opt/X11/bin/xset -q >/dev/null 2>&1
}
repair_xquartz() {
  say "Repairing XQuartz…"
  pkill -x XQuartz 2>/dev/null || true; sleep 1
  defaults delete org.xquartz.X11 >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/org.xquartz.X11.plist" || true
  rm -rf "$HOME/Library/Caches/org.xquartz.X11" || true
  rm -f "$HOME/.Xauthority" "$HOME/.serverauth."* || true
  defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
  if [ -d "/Applications/XQuartz.app" ]; then
    sudo xattr -dr com.apple.quarantine /Applications/XQuartz.app /opt/X11 2>/dev/null || true
  fi
  open -ga XQuartz || true; sleep 4
  xquartz_sanity
}

wish_path() {
  [ -x /opt/local/bin/wish8.6 ] && { printf '/opt/local/bin/wish8.6\n'; return; }
  [ -x /opt/local/bin/wish8.7 ] && { printf '/opt/local/bin/wish8.7\n'; return; }
  printf '\n'
}
tk_wish_sanity() {
  xquartz_sanity || return 1
  WISH="$(wish_path)"; [ -n "$WISH" ] || return 1
  cat > "$WORKDIR/tk_test.tcl" <<'TCL'
package require Tk
wm geometry . 200x80+120+120
label .l -text "Tk/X11 OK"; pack .l
after 300 { exit 0 }
vwait forever
TCL
  "$WISH" "$WORKDIR/tk_test.tcl" >/dev/null 2>&1
}
repair_tk() {
  say "Ensuring Tk +x11 & re-signing Tcl/Tk (Sequoia fix)…"
  if command -v port >/dev/null 2>&1; then
    /opt/local/bin/port -N upgrade --enforce-variants tk +x11 >/dev/null 2>&1 || \
    /opt/local/bin/port -N install tk +x11
    sudo xattr -dr com.apple.quarantine /opt/local 2>/dev/null || true
    find /opt/local -type f \( -name 'libtcl*.dylib' -o -name 'libtk*.dylib' -o -name 'tclsh*' -o -name 'wish*' \) -print |
    while IFS= read -r f; do sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true; done
    /opt/local/bin/port -N rev-upgrade >/dev/null 2>&1 || true
  else
    warn "MacPorts not found; skipping Tk repair."
  fi
}

need_xcode() {
  say "Checking Xcode Command Line Tools…"
  if xcode-select -p >/dev/null 2>&1; then mark_pass "Xcode Command Line Tools present"
  else
    say "Prompting install of Command Line Tools… accept Apple dialog"
    xcode-select --install || true
    if xcode-select -p >/dev/null 2>&1; then mark_pass "Xcode Command Line Tools installed"
    else mark_fail "Xcode Command Line Tools" "Not installed"; fi
  fi
}

fix_macports_signing() {
  sudo xattr -dr com.apple.quarantine /opt/local 2>/dev/null || true
  find /opt/local -type f \( -name 'tclsh*' -o -name '*.dylib' \) -print |
  while IFS= read -r f; do sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true; done
}
macports_ok() {
  /usr/bin/env -i PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" "$MACPORTS_PREFIX/bin/port" version >/dev/null 2>&1
}
install_macports() {
  ensure_path
  if command -v port >/dev/null 2>&1; then
    if macports_ok; then sudo port -v selfupdate >/dev/null 2>&1 || true; mark_pass "MacPorts CLI ready"; return; fi
    fix_macports_signing; if macports_ok; then mark_pass "MacPorts fixed"; return; fi
  fi
  ensure_dir "$WORKDIR"
  cd "$WORKDIR"
  swmaj="$(sw_vers -productVersion | awk -F. '{print $1}')"
  case "$swmaj" in
    15) PKG="MacPorts-2.10.4-15-Sequoia.pkg" ;;
    14) PKG="MacPorts-2.10.4-14-Sonoma.pkg" ;;
    13) PKG="MacPorts-2.10.4-13-Ventura.pkg" ;;
    12) PKG="MacPorts-2.10.4-12-Monterey.pkg" ;;
    *)  mark_fail "MacPorts" "Unsupported macOS $(sw_vers -productVersion)"; return ;;
  esac
  say "Installing MacPorts ($PKG)…"
  curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/${PKG}" -o "$PKG"
  sudo installer -pkg "$PKG" -target /
  ensure_path
  if sudo /opt/local/bin/port -v selfupdate >/dev/null 2>&1; then mark_pass "MacPorts installed"
  else fix_macports_signing; if sudo /opt/local/bin/port -v selfupdate >/dev/null 2>&1; then mark_pass "MacPorts installed (post-signing-fix)"; else mark_fail "MacPorts" "selfupdate failed"; fi
  fi
}

ensure_xquartz() {
  say "Ensuring XQuartz…"
  if [ ! -d "/Applications/XQuartz.app" ] && [ ! -d "/Applications/Utilities/XQuartz.app" ]; then
    ensure_dir "$WORKDIR"; cd "$WORKDIR"
    curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest -o xq.json
    PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json || true)"
    [ -n "$PKG_URL" ] || { mark_fail "XQuartz" "could not detect pkg URL"; return; }
    curl -fL "$PKG_URL" -o XQuartz.pkg
    sudo installer -pkg XQuartz.pkg -target /
  fi
  defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
  if xquartz_sanity; then mark_pass "XQuartz running (DISPLAY=$(xquartz_display))"
  else
    warn "XQuartz sanity failed; attempting repair…"
    if repair_xquartz && xquartz_sanity; then mark_pass "XQuartz repaired and running"
    else mark_fail "XQuartz" "Repair failed"; fi
  fi
}

ports_install_magic() {
  say "Installing Magic (+x11) and tools…"
  sudo port -N upgrade --enforce-variants tk +x11 >/dev/null 2>&1 || sudo port -N install tk +x11 >/dev/null 2>&1 || true
  sudo port -N upgrade --enforce-variants magic +x11 -quartz >/dev/null 2>&1 || sudo port -N install magic +x11 >/dev/null 2>&1 || true
  sudo port -N install ngspice netgen git gawk wget tcl tk >/dev/null 2>&1 || true
  MP="$(magic_path)"
  if [ -n "$MP" ]; then mark_pass "Magic at $MP"; else mark_fail "Magic" "MacPorts install failed"; fi
}

install_pdk() {
  say "Installing SKY130 PDK via open_pdks…"
  ensure_dir "$PDK_PREFIX" sudo
  sudo chown "$(id -u)":"$(id -g)" "$PDK_PREFIX" || true
  ensure_dir "$WORKDIR"; cd "$WORKDIR"
  if [ -d open_pdks/.git ]; then (cd open_pdks && git pull --rebase >/dev/null 2>&1)
  else git clone https://github.com/RTimothyEdwards/open_pdks.git >/dev/null 2>&1 || true
  fi
  cd open_pdks || { mark_fail "SKY130 PDK" "open_pdks dir missing"; return; }
  ./configure --prefix="$PDK_PREFIX" --enable-sky130-pdk --with-sky130-local-path="$PDK_PREFIX" --enable-sram-sky130 >/dev/null 2>&1 || true
  make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null 2>&1 || true
  sudo make install >/dev/null 2>&1 || true
  if pdk_loc >/dev/null 2>&1; then mark_pass "SKY130 PDK installed"; else mark_fail "SKY130 PDK" "not detected under /opt or /usr/local"; fi
}

write_demo_and_rc() {
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
  mark_pass "Demo + rc wrapper written"
}

install_launchers() {
  say "Installing launchers…"
  tdir="/usr/local/bin"
  sudo install -d -m 755 "$tdir"

  # normal
  sudo tee "$tdir/magic-sky130" >/dev/null <<'EOF'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
read set1 set2 <<EOF2
$(choose_pdk || true)
EOF2
if [ -z "${set1:-}" ]; then echo "No SKY130 PDK found."; exit 1; fi
PDK_ROOT="$set1"; PDK="$set2"; export PDK_ROOT PDK
MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic binary not found."; exit 1; }
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
pgrep -f XQuartz >/dev/null 2>&1 || { open -a XQuartz || true; sleep 3; }
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done; fi
export DISPLAY="${LDISP:-:0}"
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
  sudo chmod +x "$tdir/magic-sky130"

  # xsafe
  sudo tee "$tdir/magic-sky130-xsafe" >/dev/null <<'EOF'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
pkill -x XQuartz 2>/dev/null || true
open -ga XQuartz || true
sleep 4
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done; fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic binary not found."; exit 1; }
read set1 set2 <<EOF2
$(choose_pdk || true)
EOF2
[ -n "${set1:-}" ] || { echo "No SKY130 PDK found"; exit 1; }
PDK_ROOT="$set1"; PDK="$set2"
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
  sudo chmod +x "$tdir/magic-sky130-xsafe"

  mark_pass "Launchers installed in $tdir"
}

headless_check() {
  MP="$(magic_path)"; [ -n "$MP" ] || { mark_fail "Magic tech check" "magic not found"; return; }
  if pdk_loc >/dev/null 2>&1; then :; else mark_fail "Magic tech check" "PDK not found"; return; fi
  ensure_dir "$WORKDIR"
  cat > "$WORKDIR/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
  set -- $(pdk_loc); PBASE="$1"; PNAME="$2"
  /usr/bin/env -i PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" PDK_ROOT="$PBASE" PDK="$PNAME" \
    "$MP" -norcfile -dnull -noconsole -T "$PNAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$WORKDIR/smoke.tcl" \
    >"$LOGDIR/magic_headless.log" 2>&1 || true
  if grep -q ">>> smoke: tech=" "$LOGDIR/magic_headless.log" 2>/dev/null; then mark_pass "Magic headless tech load"
  else mark_fail "Magic headless tech load" "see $LOGDIR/magic_headless.log"; fi
}

gui_probe() {
  # Start Magic briefly with X11; if it segfaults (exit 139) we'll know.
  MP="$(magic_path)"; [ -n "$MP" ] || { echo 139; return; }
  read set1 set2 <<EOF2
$(pdk_loc || true)
EOF2
  [ -n "${set1:-}" ] || { echo 139; return; }
  PBASE="$set1"; PNAME="$set2"
  cat > "$WORKDIR/gui_probe.tcl" <<'EOF'
after 400 { exit 0 }
vwait forever
EOF
  open -ga XQuartz || true; sleep 3
  DISP="$(xquartz_display)"; export DISPLAY="$DISP"
  /opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
  "$MP" -norcfile -d X11 -T "$PNAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$WORKDIR/gui_probe.tcl" >/dev/null 2>&1 || true
  echo $?
}

install_build_deps() {
  if command -v port >/dev/null 2>&1; then
    /opt/local/bin/port -N install git autoconf automake libtool pkgconfig tcl tk \
      libX11 libXext libXrender libXft libXpm xorgproto cairo zlib >/dev/null 2>&1 || true
  fi
}

build_magic_nogl() {
  say "Building Magic ($MAGIC_VER) without OpenGL…"
  ensure_dir "$WORKDIR"; ensure_dir "$LOGDIR"
  rm -rf "$SRC_NOG"; mkdir -p "$SRC_NOG"
  cd "$WORKDIR"
  curl -fL "$MAGIC_URL" -o magic.tar.gz
  tar xf magic.tar.gz
  mv "magic-$MAGIC_VER" "$SRC_NOG"
  if [ ! -f "$SRC_NOG/database/database.h" ]; then
    mark_fail "magic-nogl" "header missing after unpack"; return 1
  fi
  cd "$SRC_NOG"
  CPPFLAGS="-I/opt/local/include -I/opt/X11/include ${CPPFLAGS:-}"; export CPPFLAGS
  LDFLAGS="-L/opt/local/lib -L/opt/X11/lib ${LDFLAGS:-}"; export LDFLAGS
  CFLAGS="-O2 -DNO_OPENGL -DNO_OGL" \
  ./configure --prefix=/usr/local --with-x --with-tcl=/opt/local --with-tk=/opt/local \
              --without-opengl --disable-opengl > "$LOGDIR/configure_nogl.log" 2>&1 || {
    mark_fail "magic-nogl configure" "see $LOGDIR/configure_nogl.log"; return 1; }
  make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" > "$LOGDIR/magic_nogl_build.log" 2>&1 || {
    mark_fail "magic-nogl build" "see $LOGDIR/magic_nogl_build.log"; return 1; }
  sudo make install >> "$LOGDIR/magic_nogl_build.log" 2>&1 || {
    mark_fail "magic-nogl install" "see $LOGDIR/magic_nogl_build.log"; return 1; }
  if [ -x /usr/local/bin/magic ]; then mark_pass "magic (no-GL) installed at /usr/local/bin/magic"
  else mark_fail "magic (no-GL)" "binary missing"; return 1; fi
}

install_launcher_nogl() {
  sudo install -d -m 755 /usr/local/bin
  sudo tee /usr/local/bin/magic-sky130-nogl >/dev/null <<'EOF'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
pgrep -x XQuartz >/dev/null 2>&1 || { open -ga XQuartz || true; sleep 4; }
LDISP="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LDISP:-}" ]; then for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done; fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic (nogl) not found at /usr/local/bin/magic"; exit 1; }
read set1 set2 <<EOF2
$( { for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; exit 0; }; done; done; exit 1; } || true )
EOF2
[ -n "${set1:-}" ] || { echo "No SKY130 PDK found"; exit 1; }
PDK_ROOT="$set1"; PDK="$set2"
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
export TK_NO_APPINIT=1 TCLLIBPATH="" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" TK_NO_APPINIT=1 TCLLIBPATH="" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
  sudo chmod +x /usr/local/bin/magic-sky130-nogl
  mark_pass "magic-sky130-nogl launcher installed"
}

summary() {
  echo
  say "==== INSTALL SUMMARY ===="
  [ -n "$PASS" ] && { printf '%s' "Passed:\n$PASS"; }
  if [ -n "$FAIL" ]; then
    printf '%s' "Failed:\n$FAIL"
    err "Review the messages above. Logs: $LOGDIR"
    exit 1
  else
    ok "All checks passed."
    echo
    say "Run:"
    say "  • magic-sky130           (GUI)"
    say "  • magic-sky130-xsafe     (GUI, software GL)"
    [ -x /usr/local/bin/magic-sky130-nogl ] && say "  • magic-sky130-nogl      (GUI, no OpenGL)"
    echo
    say "Demo (SPICE):  cd \"$DEMO_DIR\" && ngspice inverter_tt.spice"
    exit 0
  fi
}

main() {
  ensure_dir "$WORKDIR"; ensure_dir "$LOGDIR"; ensure_dir "$RC_DIR"; ensure_dir "$DEMO_DIR"
  need_xcode
  install_macports
  ensure_path
  ensure_xquartz
  if tk_wish_sanity; then mark_pass "Tk/Wish GUI sanity" else warn "Tk/Wish failed; repairing…"; repair_tk || true; tk_wish_sanity && mark_pass "Tk/Wish repaired" || mark_fail "Tk/Wish" "still failing"; fi
  ports_install_magic
  install_pdk
  write_demo_and_rc
  install_launchers
  headless_check

  # GUI probe -> fallback logic
  code="$(gui_probe || echo 139)"
  if [ "$code" -eq 0 ]; then
    mark_pass "Magic GUI probe OK"
  else
    warn "Magic GUI probe failed (exit $code). Trying xsafe probe…"
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe=1
    code2="$(gui_probe || echo 139)"
    if [ "$code2" -eq 0 ]; then
      mark_pass "Magic GUI (software GL) OK — use: magic-sky130-xsafe"
    else
      warn "GUI still failing; building OpenGL-free Magic…"
      install_build_deps
      build_magic_nogl && install_launcher_nogl || true
    fi
  fi
  summary
}
main "$@"
