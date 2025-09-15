#!/bin/sh
# Robust Magic + SKY130 PDK installer for macOS (arm64/intel)
# - Progress bar + spinner
# - Idempotent & noisy logging
# - OpenGL crash fallbacks (xsafe + nogl build)
# - Tested on Apple Silicon (M1/M2) and Intel (Monterey → Sequoia)
#
# Launchers after install:
#   magic-sky130           # normal GUI
#   magic-sky130-xsafe     # software GL (llvmpipe) if GPU is crashy
#   magic-sky130-nogl      # no-OpenGL build (created only if needed)

set -Eeuo pipefail

### --------- Config ---------
MACPORTS_PREFIX="/opt/local"
PDK_PREFIX="/opt/pdk"
WORKDIR="$HOME/.eda-bootstrap"
LOGDIR="$WORKDIR/logs"
DEMO_DIR="$HOME/sky130-demo"
RC_DIR="$HOME/.config/sky130"
SRC_NOG="$WORKDIR/magic-nogl"
MAGIC_VER="${MAGIC_VER:-8.3.551}"
MAGIC_URL="https://github.com/RTimothyEdwards/magic/archive/refs/tags/$MAGIC_VER.tar.gz"
TOTAL_STEPS=14

PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

mkdir -p "$WORKDIR" "$LOGDIR" "$RC_DIR" "$DEMO_DIR"

LOG="$LOGDIR/install.$(date +%Y%m%d-%H%M%S).log"
touch "$LOG"
exec 3>&1

say()  { printf "%s\n" "$*" >&3; }
ok()   { printf "✓ %s\n" "$*" >&3; }
warn() { printf "⚠ %s\n" "$*" >&3; }
err()  { printf "✗ %s\n" "$*" >&3; }

STEP=0
bar() {
  # simple progress bar [#####.....] N/T
  STEP=$((STEP+1))
  done=$((STEP*20/TOTAL_STEPS))
  [ $done -gt 20 ] && done=20
  remain=$((20-done))
  printf "[%s%s] (%2d/%2d) %s\n" "$(printf "%0.s#" $(seq 1 $done))" "$(printf "%0.s." $(seq 1 $remain))" "$STEP" "$TOTAL_STEPS" "$1" >&3
}

spinner() {
  pid="$1"
  msg="$2"
  chars='-\|/'
  i=1
  while kill -0 "$pid" 2>/dev/null; do
    c=$(printf "%s" "$chars" | cut -c $i)
    printf "\r  %s %s" "$c" "$msg" >&3
    i=$((i+1)); [ $i -gt 4 ] && i=1
    sleep 0.15
  done
  printf "\r  \r" >&3
}

run() {
  # run "Title" cmd...
  title="$1"; shift
  bar "$title"
  {
    printf "\n--- %s --- %s ---\n" "$(date)" "$title" >>"$LOG"
    "$@" >>"$LOG" 2>&1
  } &
  pid=$!
  spinner "$pid" "$title"
  wait "$pid" || { err "$title (see $LOG)"; exit 1; }
  ok "$title"
}

trap 'err "Installer aborted. See log: $LOG"' INT TERM
cleanup() { :; }
trap cleanup EXIT

### --------- Helpers ---------
need_cmd() { command -v "$1" >/dev/null 2>&1; }
os_major() { sw_vers -productVersion | awk -F. '{print $1}'; }
arch_name() { uname -m; }

magic_path() {
  [ -x "$MACPORTS_PREFIX/bin/magic" ] && { printf '%s\n' "$MACPORTS_PREFIX/bin/magic"; return; }
  [ -x /usr/local/bin/magic ] && { printf '/usr/local/bin/magic\n'; return; }
  printf '\n'
}
wish_path() {
  for w in "$MACPORTS_PREFIX/bin/wish8.7" "$MACPORTS_PREFIX/bin/wish8.6" /usr/local/bin/wish8.7 /usr/local/bin/wish8.6; do
    [ -x "$w" ] && { printf '%s\n' "$w"; return; }
  done
  printf '\n'
}
pdk_loc() {
  for base in "$PDK_PREFIX" "$PDK_PREFIX/share/pdk" /usr/local/share/pdk; do
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
  printf ':0\n'
}
xquartz_sanity() {
  pgrep -x XQuartz >/dev/null 2>&1 || { open -ga XQuartz || true; sleep 4; }
  DISP="$(xquartz_display)"; export DISPLAY="$DISP"
  /opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
  /opt/X11/bin/xset -q >/dev/null 2>&1
}
install_x11_libs() {
  pkgs="xorgproto libXau libXdmcp libxcb libX11 libXext libXrender libXft libXpm zlib cairo"
  for p in $pkgs; do
    echo ">> installing $p"
    sudo port -N -f clean --all "$p" >>"$LOG" 2>&1 || true
    sudo port -N install "$p" >>"$LOG" 2>&1 || sudo port -d install "$p" >>"$LOG" 2>&1 || {
      echo "!! $p failed, showing last 60 log lines:" >>"$LOG"
      tail -n 60 "/opt/local/var/macports/logs"/*/"$p"/*.log >>"$LOG" 2>&1 || true
      return 1
    }
  done
  sudo port -N rev-upgrade >>"$LOG" 2>&1 || true
}

### --------- Steps ---------
say "Log: $LOG"
say "Architecture: $(arch_name), macOS $(sw_vers -productVersion)"
bar "Pre-authenticate sudo (keepalive)"
# sudo keepalive
sudo -v
# keep sudo alive while we run
( while true; do sleep 30; sudo -n true 2>/dev/null || true; done ) >/dev/null 2>&1 &
SUDO_PID=$!

bar "Check Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then ok "Xcode CLT present"
else
  say "Prompting Apple installer for CLT…"
  xcode-select --install || true
  # poll a bit
  for i in $(seq 1 30); do xcode-select -p >/dev/null 2>&1 && break; sleep 2; done
  xcode-select -p >/dev/null 2>&1 || { err "Xcode CLT missing"; exit 1; }
  ok "Xcode CLT installed"
fi

bar "Ensure MacPorts"
if need_cmd port; then
  run "MacPorts selfupdate" sudo "$MACPORTS_PREFIX/bin/port" -v selfupdate
else
  MPKG=""
  case "$(os_major)" in
    12) MPKG="MacPorts-2.10.4-12-Monterey.pkg" ;;
    13) MPKG="MacPorts-2.10.4-13-Ventura.pkg" ;;
    14) MPKG="MacPorts-2.10.4-14-Sonoma.pkg" ;;
    15) MPKG="MacPorts-2.10.4-15-Sequoia.pkg" ;;
    *)  err "Unsupported macOS $(sw_vers -productVersion)"; exit 1 ;;
  esac
  run "Download MacPorts ($MPKG)" curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/${MPKG}" -o "$WORKDIR/$MPKG"
  run "Install MacPorts" sudo installer -pkg "$WORKDIR/$MPKG" -target /
  run "MacPorts selfupdate" sudo "$MACPORTS_PREFIX/bin/port" -v selfupdate
fi

bar "De-quarantine & sign MacPorts (Tcl/Tk edge-cases)"
sudo xattr -dr com.apple.quarantine "$MACPORTS_PREFIX" 2>/dev/null || true
# best-effort ad-hoc sign critical dylibs/binaries (Sequoia fix)
find "$MACPORTS_PREFIX" -type f \( -name 'libtcl*.dylib' -o -name 'libtk*.dylib' -o -name 'tclsh*' -o -name 'wish*' -o -name '*.dylib' \) 2>/dev/null | while IFS= read -r f; do
  sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true
done
ok "MacPorts binaries normalized"

bar "Ensure XQuartz"
if [ ! -d "/Applications/XQuartz.app" ] && [ ! -d "/Applications/Utilities/XQuartz.app" ]; then
  # get latest pkg url via GitHub API
  run "Fetch XQuartz release JSON" curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest -o "$WORKDIR/xq.json"
  PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' "$WORKDIR/xq.json" || true)"
  [ -n "$PKG_URL" ] || { err "Could not detect XQuartz pkg URL"; exit 1; }
  run "Download XQuartz" curl -fL "$PKG_URL" -o "$WORKDIR/XQuartz.pkg"
  run "Install XQuartz" sudo installer -pkg "$WORKDIR/XQuartz.pkg" -target /
fi
defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
xquartz_sanity || { err "XQuartz sanity failed"; exit 1; }
ok "XQuartz running (DISPLAY=$(xquartz_display))"

bar "Install Tcl/Tk +X11 and tools"
run "Install Tk +x11" sudo port -N upgrade --enforce-variants tk +x11 || sudo port -N install tk +x11
run "Install toolchain" sudo port -N install git autoconf automake libtool pkgconfig
run "Install X11 libs (robust)" install_x11_libs

bar "Install Magic (+x11) & EDA tools"
run "Install Magic +x11" sudo port -N upgrade --enforce-variants magic +x11 -quartz || sudo port -N install magic +x11
run "Install ngspice netgen etc." sudo port -N install ngspice netgen gawk wget tcl tk
run "rev-upgrade" sudo port -N rev-upgrade

bar "Write demo SPICE + Magic RC wrapper"
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
ok "Demo + rc created"

bar "Install SKY130 PDK (open_pdks)"
if [ -d "$WORKDIR/open_pdks/.git" ]; then
  run "Update open_pdks" sh -c 'cd "$WORKDIR/open_pdks" && git pull --rebase'
else
  run "Clone open_pdks" git clone https://github.com/RTimothyEdwards/open_pdks.git "$WORKDIR/open_pdks"
fi
run "Configure open_pdks" sh -c 'cd "$WORKDIR/open_pdks" && ./configure --prefix="'"$PDK_PREFIX"'" --enable-sky130-pdk --with-sky130-local-path="'"$PDK_PREFIX"'" --enable-sram-sky130'
run "Build open_pdks"    sh -c 'cd "$WORKDIR/open_pdks" && make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"'
run "Install PDK"        sudo make -C "$WORKDIR/open_pdks" install
if pdk_loc >/dev/null 2>&1; then ok "SKY130 PDK installed"
else err "SKY130 PDK not detected under $PDK_PREFIX"; exit 1; fi

bar "Install Magic launchers"
sudo install -d -m 755 /usr/local/bin
cat | sudo tee /usr/local/bin/magic-sky130 >/dev/null <<'EOF'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
set -- $(choose_pdk || true)
[ $# -ge 2 ] || { echo "No SKY130 PDK found."; exit 1; }
PDK_ROOT="$1"; PDK="$2"; export PDK_ROOT PDK
MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic binary not found."; exit 1; }
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
pgrep -f XQuartz >/dev/null 2>&1 || { open -ga XQuartz || true; sleep 3; }
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done; fi
export DISPLAY="${LDISP:-:0}"
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
chmod +x /usr/local/bin/magic-sky130

cat | sudo tee /usr/local/bin/magic-sky130-xsafe >/dev/null <<'EOF'
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
set -- $(choose_pdk || true)
[ $# -ge 2 ] || { echo "No SKY130 PDK found"; exit 1; }
PDK_ROOT="$1"; PDK="$2"
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
chmod +x /usr/local/bin/magic-sky130-xsafe
ok "Launchers installed"

bar "Headless Magic tech-load smoke test"
MP="$(magic_path)"; if [ -z "$MP" ]; then err "magic not found"; exit 1; fi
set -- $(pdk_loc || true); [ $# -ge 2 ] || { err "PDK not found"; exit 1; }
PBASE="$1"; PNAME="$2"
cat > "$WORKDIR/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
# headless device
"$MP" -norcfile -dnull -noconsole -T "$PNAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$WORKDIR/smoke.tcl" >"$LOGDIR/magic_headless.log" 2>&1 || true
grep -q ">>> smoke: tech=" "$LOGDIR/magic_headless.log" && ok "Magic headless tech load" || { err "Headless tech load failed (see $LOGDIR/magic_headless.log)"; exit 1; }

bar "GUI probe (X11)"
open -ga XQuartz || true; sleep 3
DISP="$(xquartz_display)"; export DISPLAY="$DISP"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
cat > "$WORKDIR/gui_probe.tcl" <<'EOF'
after 400 { exit 0 }
vwait forever
EOF
"$MP" -norcfile -d X11 -T "$PNAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$WORKDIR/gui_probe.tcl" >/dev/null 2>&1 || true
GUI_STATUS=$?
if [ "$GUI_STATUS" -eq 0 ]; then
  ok "Magic GUI OK"
else
  warn "Magic GUI failed (exit $GUI_STATUS). Trying software GL…"
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
  "$MP" -norcfile -d X11 -T "$PNAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$WORKDIR/gui_probe.tcl" >/dev/null 2>&1 || true
  GUI2=$?
  if [ "$GUI2" -eq 0 ]; then
    ok "GUI OK with software GL — use: magic-sky130-xsafe"
  else
    warn "GUI still failing; building OpenGL-free Magic…"
    # Build Magic without OpenGL
    run "Fetch Magic sources" sh -c 'rm -rf "'"$SRC_NOG"'" && mkdir -p "'"$SRC_NOG"'" && cd "'"$WORKDIR"'" && curl -fL "'"$MAGIC_URL"'" -o magic.tar.gz && tar xf magic.tar.gz && mv "magic-'"$MAGIC_VER"'" "'"$SRC_NOG"'"'
    run "Configure magic (nogl)" sh -c 'cd "'"$SRC_NOG"'" && CPPFLAGS="-I/opt/local/include -I/opt/X11/include ${CPPFLAGS:-}" LDFLAGS="-L/opt/local/lib -L/opt/X11/lib ${LDFLAGS:-}" CFLAGS="-O2 -DNO_OPENGL -DNO_OGL" ./configure --prefix=/usr/local --with-x --with-tcl=/opt/local --with-tk=/opt/local --without-opengl --disable-opengl'
    run "Build magic (nogl)"     sh -c 'cd "'"$SRC_NOG"'" && make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"'
    run "Install magic (nogl)"   sudo make -C "$SRC_NOG" install
    cat | sudo tee /usr/local/bin/magic-sky130-nogl >/dev/null <<'EOF2'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
pgrep -x XQuartz >/dev/null 2>&1 || { open -ga XQuartz || true; sleep 4; }
LDISP="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LDISP:-}" ]; then for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done; fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic (nogl) not found at /usr/local/bin/magic"; exit 1; }
set -- $(choose_pdk || true)
[ $# -ge 2 ] || { echo "No SKY130 PDK found"; exit 1; }
PDK_ROOT="$1"; PDK="$2"
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
export TK_NO_APPINIT=1 TCLLIBPATH="" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" TK_NO_APPINIT=1 TCLLIBPATH="" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF2
    sudo chmod +x /usr/local/bin/magic-sky130-nogl
    ok "Installed magic-sky130-nogl (no-OpenGL build)"
  fi
fi

# Kill sudo keepalive
kill "$SUDO_PID" >/dev/null 2>&1 || true

say ""
ok "All done!"
say "Log: $LOG"
say "Run:"
say "  • magic-sky130           (GUI)"
say "  • magic-sky130-xsafe     (GUI with software GL)"
[ -x /usr/local/bin/magic-sky130-nogl ] && say "  • magic-sky130-nogl      (GUI without OpenGL)"
say ""
say "SPICE quick test:"
say "  cd \"$DEMO_DIR\" && ngspice inverter_tt.spice"
