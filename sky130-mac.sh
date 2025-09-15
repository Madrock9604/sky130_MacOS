#!/bin/sh
# sky130_setup.sh — Minimal, robust Magic + SKY130 PDK installer with explicit verification
# macOS 12–15 (Monterey, Ventura, Sonoma, Sequoia). Intel & Apple Silicon.
# Steps:
# 1) Verify Xcode CLT
# 2) Install/verify MacPorts (OS-aware)
# 3) Install/verify XQuartz + X11
# 4) Install/verify Magic (MacPorts)
# 5) Install/verify SKY130 PDK (open_pdks)
# 6) Install launchers
# All actions logged. Short, precise errors echoed to screen.

set -Eeuo pipefail

### --- Config/paths ---
MACPORTS_PREFIX="/opt/local"
PORTCMD="$MACPORTS_PREFIX/bin/port"
PDK_PREFIX="/opt/pdk"
WORKDIR="$HOME/.eda-bootstrap"
LOGDIR="$WORKDIR/logs"
RC_DIR="$HOME/.config/sky130"
DEMO_DIR="$HOME/sky130-demo"
OPENPDKS_DIR="$WORKDIR/open_pdks"
LOG="$LOGDIR/install.$(date +%Y%m%d-%H%M%S).log"

PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

mkdir -p "$WORKDIR" "$LOGDIR" "$RC_DIR" "$DEMO_DIR"
touch "$LOG"
exec 3>&1  # human output

say()  { printf "%s\n" "$*" >&3; }
ok()   { printf "OK: %s\n" "$*" >&3; }
err()  { printf "ERROR: %s\n" "$*" >&3; }
section(){ printf "\n--- %s ---\n" "$*" >>"$LOG"; }

on_fail() {
  err "$1 (see log: $LOG)"
  exit 1
}

os_major() { sw_vers -productVersion | awk -F. '{print $1}'; }

xquartz_display() {
  LD="$(launchctl getenv DISPLAY 2>/dev/null || true)"
  if [ -n "${LD:-}" ]; then printf '%s\n' "$LD"; return; fi
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && { printf '%s\n' "$d/org.xquartz:0"; return; }
  done
  printf ':0\n'
}

### --- 1) Xcode CLT ---
section "Xcode CLT check"
if xcode-select -p >>"$LOG" 2>&1; then
  ok "Xcode Command Line Tools present"
else
  say "Requesting Xcode CLT…"
  if xcode-select --install >>"$LOG" 2>&1 || true; then
    for i in $(seq 1 60); do
      xcode-select -p >>"$LOG" 2>&1 && break
      sleep 2
    done
  fi
  xcode-select -p >>"$LOG" 2>&1 || on_fail "Xcode CLT not installed. Run: xcode-select --install"
  ok "Xcode CLT installed"
fi

### --- 2) MacPorts install + verify ---
section "MacPorts install"
if [ ! -x "$PORTCMD" ]; then
  case "$(os_major)" in
    12) PKG="MacPorts-2.10.4-12-Monterey.pkg" ;;
    13) PKG="MacPorts-2.10.4-13-Ventura.pkg" ;;
    14) PKG="MacPorts-2.10.4-14-Sonoma.pkg" ;;
    15) PKG="MacPorts-2.10.4-15-Sequoia.pkg" ;;
    *) on_fail "Unsupported macOS $(sw_vers -productVersion) for auto MacPorts install" ;;
  esac
  say "Installing MacPorts ($PKG)…"
  curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/$PKG" -o "$WORKDIR/$PKG" >>"$LOG" 2>&1 || on_fail "Download MacPorts failed"
  sudo installer -pkg "$WORKDIR/$PKG" -target / >>"$LOG" 2>&1 || on_fail "MacPorts installer failed"
fi
# Verify
section "MacPorts verify"
sudo "$PORTCMD" -v selfupdate >>"$LOG" 2>&1 || on_fail "MacPorts selfupdate failed"
"$PORTCMD" version >>"$LOG" 2>&1 || on_fail "MacPorts CLI missing after install"
ok "MacPorts ready"

### --- 3) XQuartz install + verify (X11 sanity) ---
section "XQuartz install/verify"
if [ ! -d "/Applications/XQuartz.app" ] && [ ! -d "/Applications/Utilities/XQuartz.app" ]; then
  say "Installing XQuartz…"
  curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest -o "$WORKDIR/xq.json" >>"$LOG" 2>&1 || on_fail "Fetch XQuartz release info failed"
  PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' "$WORKDIR/xq.json" || true)"
  [ -n "$PKG_URL" ] || on_fail "XQuartz package URL not found"
  curl -fL "$PKG_URL" -o "$WORKDIR/XQuartz.pkg" >>"$LOG" 2>&1 || on_fail "Download XQuartz failed"
  sudo installer -pkg "$WORKDIR/XQuartz.pkg" -target / >>"$LOG" 2>&1 || on_fail "XQuartz installer failed"
fi
defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
# Bring up XQuartz + verify X11 responds
open -ga XQuartz >>"$LOG" 2>&1 || true
sleep 3
DISP="$(xquartz_display)"; export DISPLAY="$DISP"
# X11 double-checks:
if ! /opt/X11/bin/xset -q >>"$LOG" 2>&1; then on_fail "X11 not responding via XQuartz"; fi
/opt/X11/bin/xhost +SI:localuser:"$USER" >>"$LOG" 2>&1 || true
ok "XQuartz/X11 OK (DISPLAY=$DISP)"

### --- 4) Magic install (MacPorts) + verify ---
section "Magic install"
# Ensure Tcl/Tk (+x11) first
sudo "$PORTCMD" -N upgrade --enforce-variants tk +x11 >>"$LOG" 2>&1 || sudo "$PORTCMD" -N install tk +x11 >>"$LOG" 2>&1 || on_fail "Tk +x11 install failed"
# Magic + EDA friends
sudo "$PORTCMD" -N upgrade --enforce-variants magic +x11 -quartz >>"$LOG" 2>&1 || sudo "$PORTCMD" -N install magic +x11 >>"$LOG" 2>&1 || on_fail "Magic install failed"
sudo "$PORTCMD" -N install ngspice netgen gawk wget tcl tk >>"$LOG" 2>&1 || on_fail "ngspice/netgen install failed"
sudo "$PORTCMD" -N rev-upgrade >>"$LOG" 2>&1 || true
# Verify magic binary
MAGIC_BIN="$MACPORTS_PREFIX/bin/magic"
[ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || on_fail "Magic binary not found after install"
ok "Magic installed ($MAGIC_BIN)"

### --- 5) SKY130 PDK install + verify ---
section "SKY130 PDK (open_pdks)"
sudo install -d -m 755 "$PDK_PREFIX" >>"$LOG" 2>&1 || true
sudo chown "$(id -u)":"$(id -g)" "$PDK_PREFIX" >>"$LOG" 2>&1 || true

if [ -d "$OPENPDKS_DIR/.git" ]; then
  (cd "$OPENPDKS_DIR" && git pull --rebase) >>"$LOG" 2>&1 || on_fail "open_pdks update failed"
else
  git clone https://github.com/RTimothyEdwards/open_pdks.git "$OPENPDKS_DIR" >>"$LOG" 2>&1 || on_fail "open_pdks clone failed"
fi
(
  cd "$OPENPDKS_DIR"
  ./configure --prefix="$PDK_PREFIX" --enable-sky130-pdk --with-sky130-local-path="$PDK_PREFIX" --enable-sram-sky130
  make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  sudo make install
) >>"$LOG" 2>&1 || on_fail "open_pdks build/install failed"

# Verify PDK files exist
if [ -f "$PDK_PREFIX/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
  export PDK_ROOT="$PDK_PREFIX"; export PDK="sky130A"
elif [ -f "$PDK_PREFIX/share/pdk/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
  export PDK_ROOT="$PDK_PREFIX/share/pdk"; export PDK="sky130A"
else
  on_fail "SKY130 PDK not found under $PDK_PREFIX"
fi
ok "SKY130 PDK detected at $PDK_ROOT/$PDK"

# Headless tech load to verify Magic+PDK together
SMOKE="$WORKDIR/smoke.tcl"
cat > "$SMOKE" <<'EOF'
puts ">>> tech=[tech name]"
quit -noprompt
EOF
"$MAGIC_BIN'notused'" >/dev/null 2>&1 || true  # dummy to satisfy shellcheck on quotes
"$MAGIC_BIN" -norcfile -dnull -noconsole -T "$PDK" -rcfile "$PDK_ROOT/$PDK/libs.tech/magic/$PDK.magicrc" "$SMOKE" >>"$LOG" 2>&1 || on_fail "Magic failed to load SKY130 tech (headless)"
grep -q ">>> tech=" "$LOG" || on_fail "Magic+PDK verification text missing"
ok "Magic loads SKY130 tech (headless check passed)"

### --- 6) RC wrapper + demo + launchers ---
section "RC & launchers"
# Nice window behavior
cat > "$RC_DIR/rc_wrapper.tcl" <<'EOF'
if {![info exists env(PDK_ROOT)]} { set env(PDK_ROOT) "/opt/pdk" }
if {![info exists env(PDK)]}      { set env(PDK)      "sky130A" }
source "$env(PDK_ROOT)/$env(PDK)/libs.tech/magic/${env(PDK)}.magicrc"
after 200 { catch { wm title . "Magic ($env(PDK)) — SKY130" } }
EOF

# Demo SPICE
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

sudo install -d -m 755 /usr/local/bin >>"$LOG" 2>&1 || true

# magic-sky130 launcher
cat | sudo tee /usr/local/bin/magic-sky130 >/dev/null <<'EOF'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { echo "$b $n"; return 0; }; done
done; return 1; }
set -- $(choose_pdk || true)
[ $# -ge 2 ] || { echo "No SKY130 PDK found."; exit 1; }
PDK_ROOT="$1"; PDK="$2"
MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic not found"; exit 1; }
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC="$PDK_ROOT/$PDK/libs.tech/magic/$PDK.magicrc"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
pgrep -x XQuartz >/dev/null 2>&1 || { open -ga XQuartz || true; sleep 3; }
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done; fi
export DISPLAY="${LDISP:-:0}"
exec "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
sudo chmod +x /usr/local/bin/magic-sky130 >>"$LOG" 2>&1 || true

# magic-sky130-xsafe launcher (software GL)
cat | sudo tee /usr/local/bin/magic-sky130-xsafe >/dev/null <<'EOF'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { echo "$b $n"; return 0; }; done
done; return 1; }
set -- $(choose_pdk || true)
[ $# -ge 2 ] || { echo "No SKY130 PDK found."; exit 1; }
PDK_ROOT="$1"; PDK="$2"
MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic not found"; exit 1; }
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC="$PDK_ROOT/$PDK/libs.tech/magic/$PDK.magicrc"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
pkill -x XQuartz 2>/dev/null || true
open -ga XQuartz || true
sleep 4
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done; fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
exec "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
sudo chmod +x /usr/local/bin/magic-sky130-xsafe >>"$LOG" 2>&1 || true

ok "Launchers installed"

### --- Done ---
say ""
ok "Install complete."
say "Log file: $LOG"
say "Run Magic:"
say "  magic-sky130        # normal"
say "  magic-sky130-xsafe  # software GL if the GUI glitches"
say "SPICE demo:"
say "  cd \"$DEMO_DIR\" && ngspice inverter_tt.spice"
