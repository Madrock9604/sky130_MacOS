#!/usr/bin/env bash
# sky130-mac.sh — Magic + SKY130 PDK on macOS (Sonoma/Sequoia/Ventura/Monterey)
# Safe, repeatable, with robust XQuartz repair, clear verification, and full logging.

set -euo pipefail

# ---------------------------- Config & Globals -----------------------------
MACPORTS_PREFIX="/opt/local"
PDK_PREFIX="/opt/pdk"
WORKDIR="$HOME/.eda-bootstrap"
LOGDIR="$WORKDIR/logs"
RC_DIR="$HOME/.config/sky130"
DEMO_DIR="$HOME/sky130-demo"

mkdir -p "$LOGDIR" "$RC_DIR" "$DEMO_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/install.$ts.log"

# Mirror output to screen + log
exec > >(tee -a "$LOG") 2>&1

# Pretty helpers
step_n=0
step()  { step_n=$((step_n+1)); printf '\n[%d] %s\n' "$step_n" "$*"; }
ok()    { printf '  ✓ %s\n' "$*"; }
warn()  { printf '  ▸ WARN: %s\n' "$*"; }
die()   { printf '  ✗ %s\n' "$*"; printf '\nLog: %s\n' "$LOG"; exit 1; }

# Prompt sudo early
step "Prepare privileges"
if sudo -v; then
  ok "sudo ready"
else
  die "Need admin privileges (sudo)."
fi

# Common PATH
export PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/opt/X11/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ---------------------------- Small utilities ------------------------------
sw_major() { sw_vers -productVersion | awk -F. '{print $1}'; }
have() { command -v "$1" >/dev/null 2>&1; }
port_ok() {
  /usr/bin/env -i PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$MACPORTS_PREFIX/bin/port" version >/dev/null 2>&1
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
xq_socket() {
  # Try launchd env then known sockets
  local d
  local ld; ld="$(launchctl getenv DISPLAY 2>/dev/null || true)"
  if [ -n "${ld:-}" ]; then printf '%s\n' "$ld"; return 0; fi
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && { printf '%s\n' "$d/org.xquartz:0"; return 0; }
  done
  printf ':0\n'
}

# ---------------------------- Xcode CLT ------------------------------------
step "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "$(xcode-select -p)"
else
  echo "  • Triggering Apple CLT installer (accept the popup)…"
  xcode-select --install || true
  # wait up to ~2 min for CLT
  for _ in {1..24}; do
    if xcode-select -p >/dev/null 2>&1; then ok "CLT installed"; break; fi
    sleep 5
  done
  xcode-select -p >/dev/null 2>&1 || die "Xcode CLT not found after install. Open App Store → install Command Line Tools."
fi

# ---------------------------- MacPorts -------------------------------------
step "MacPorts install/verify"
if have port && port_ok; then
  ok "MacPorts CLI present"
else
  mpkg=""
  case "$(sw_major)" in
    15) mpkg="MacPorts-2.11.5-15-Sequoia.pkg" ;;
    14) mpkg="MacPorts-2.11.5-14-Sonoma.pkg" ;;
    13) mpkg="MacPorts-2.11.5-13-Ventura.pkg" ;;
    12) mpkg="MacPorts-2.11.5-12-Monterey.pkg" ;;
    *)  die "Unsupported macOS $(sw_vers -productVersion) for this script." ;;
  esac
  cd "$WORKDIR"
  echo "  • Downloading $mpkg"
  curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/${mpkg}" -o "$mpkg"
  echo "  • Installing MacPorts pkg"
  sudo installer -pkg "$mpkg" -target / || die "MacPorts installer failed."
fi

# Fix potential quarantine/signing issues (Sequoia/Sonoma hardening)
sudo xattr -dr com.apple.quarantine /opt/local 2>/dev/null || true
if ! port_ok; then
  # opportunistic re-sign some dylibs/binaries (best-effort)
  find /opt/local -type f \( -name 'tclsh*' -o -name '*.dylib' -o -name 'wish*' \) 2>/dev/null | while read -r f; do
    sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true
  done
fi

# Selfupdate + basic check
if /opt/local/bin/port -v selfupdate; then
  ok "MacPorts up to date"
else
  die "MacPorts selfupdate failed."
fi
if have port && port_ok; then
  ok "MacPorts verified: $(/opt/local/bin/port version | sed -e 's/Version: //')"
else
  die "MacPorts CLI not functional after install."
fi

# ---------------------------- XQuartz --------------------------------------
step "XQuartz ensure/repair"
need_xq=0
if [ ! -x /opt/X11/bin/Xquartz ] && [ ! -d /Applications/XQuartz.app ] && [ ! -d /Applications/Utilities/XQuartz.app ]; then
  need_xq=1
fi

ensure_xquartz() {
  cd "$WORKDIR"
  echo "  • Fetching latest XQuartz release metadata"
  curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest -o xq.json || return 1
  local pkg; pkg="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json)"
  [ -n "$pkg" ] || return 1
  echo "  • Downloading XQuartz pkg"
  curl -fL "$pkg" -o XQuartz.pkg || return 1
  echo "  • Installing XQuartz"
  sudo installer -pkg XQuartz.pkg -target / || return 1
  return 0
}

repair_xquartz() {
  echo "  • Resetting XQuartz preferences & caches"
  pkill -x XQuartz 2>/dev/null || true
  defaults delete org.xquartz.X11 >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/org.xquartz.X11.plist" "$HOME/.Xauthority" "$HOME/.serverauth."* 2>/dev/null || true
  rm -rf "$HOME/Library/Caches/org.xquartz.X11" 2>/dev/null || true
  defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
  # de-quarantine the app bundle only (avoid SIP-protected font errors)
  if [ -d "/Applications/XQuartz.app" ]; then
    sudo xattr -dr com.apple.quarantine /Applications/XQuartz.app 2>/dev/null || true
  fi
}

if [ "$need_xq" -eq 1 ]; then
  ensure_xquartz || die "Failed to download/install XQuartz."
else
  ok "XQuartz appears installed"
fi

# Always try a gentle repair (safe ops)
repair_xquartz

# Bring XQuartz up and establish DISPLAY
echo "  • Launching XQuartz"
open -ga XQuartz || true
sleep 4

# Try to discover socket; if none, force DISPLAY=:0 (works on many setups)
DISPLAY="$(xq_socket)"; export DISPLAY
launchctl setenv DISPLAY "$DISPLAY" >/dev/null 2>&1 || true
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true

if /opt/X11/bin/xset -q >/dev/null 2>&1; then
  ok "X11 responding (DISPLAY=$DISPLAY)"
else
  warn "No XQuartz display socket found; falling back to DISPLAY=:0 and relaunch."
  export DISPLAY=":0"
  open -ga XQuartz || true
  sleep 4
  if /opt/X11/bin/xset -q >/dev/null 2>&1; then
    ok "X11 responding with DISPLAY=:0"
  else
    die "XQuartz/X11 did not respond. Open XQuartz manually once, grant permissions if macOS prompts, then rerun this script."
  fi
fi

# ---------------------------- MacPorts packages ----------------------------
step "Install Magic & deps via MacPorts"

# Helper: install-or-upgrade with variants
port_install_with_variants() {
  local name="$1"; shift
  local variants=("$@")  # e.g. +x11 -quartz
  if /opt/local/bin/port installed "$name" | grep -q "Active"; then
    echo "  • Upgrading $name to enforce variants ${variants[*]}"
    /opt/local/bin/port -N upgrade --enforce-variants "$name" "${variants[@]}" || die "Failed to upgrade $name."
  else
    echo "  • Installing $name ${variants[*]}"
    /opt/local/bin/port -N install "$name" "${variants[@]}" || die "Failed to install $name."
  fi
}

# Make sure rsync index is fresh (harmless if already updated)
 /opt/local/bin/port -N sync || true

port_install_with_variants tk +x11
port_install_with_variants magic +x11 -quartz

# QoL tools (best-effort)
/opt/local/bin/port -N install ngspice netgen git gawk wget tcl tk >/dev/null 2>&1 || true

if [ -x "$MACPORTS_PREFIX/bin/magic" ]; then ok "Magic installed: $("$MACPORTS_PREFIX/bin/magic" -v 2>/dev/null | head -n1)"; else die "Magic not found in $MACPORTS_PREFIX/bin."; fi

# ---------------------------- SKY130 PDK -----------------------------------
step "Install SKY130 PDK via open_pdks (this can take a while)"
mkdir -p "$PDK_PREFIX"
sudo chown "$(id -u)":"$(id -g)" "$PDK_PREFIX" || true

cd "$WORKDIR"
if [ -d open_pdks/.git ]; then
  echo "  • Updating open_pdks"
  (cd open_pdks && git pull --rebase) || die "git pull failed in open_pdks."
else
  echo "  • Cloning open_pdks"
  git clone https://github.com/RTimothyEdwards/open_pdks.git || die "git clone open_pdks failed."
fi

cd open_pdks
echo "  • configure"
./configure --prefix="$PDK_PREFIX" --enable-sky130-pdk --with-sky130-local-path="$PDK_PREFIX" --enable-sram-sky130 >/dev/null \
  || die "open_pdks configure failed (see log)."
echo "  • build"
make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null || die "open_pdks build failed."
echo "  • install"
sudo make install >/dev/null || die "open_pdks install failed."

if pdk_loc >/dev/null 2>&1; then
  ok "SKY130 PDK installed"
else
  die "SKY130 PDK not detected under /opt or /usr/local."
fi

# ---------------------------- rc_wrapper.tcl -------------------------------
step "Write Tk-safe Magic rc wrapper"
RC_FILE="$RC_DIR/rc_wrapper.tcl"
if [ -f "$RC_FILE" ]; then
  cp -f "$RC_FILE" "$RC_FILE.bak.$ts"
  echo "  • Backed up existing rc to $RC_FILE.bak.$ts"
fi
cat > "$RC_FILE" <<'EOF'
# Tk-safe wrapper rc for Magic + SKY130
# Always source the PDK rc; only do Tk window tweaks if Tk commands are available.
if {![info exists env(PDK_ROOT)]} { set env(PDK_ROOT) "/opt/pdk" }
if {![info exists env(PDK)]}      { set env(PDK)      "sky130A" }

set ::sky130::pdk_rc [file join $env(PDK_ROOT) $env(PDK) libs.tech magic "${env(PDK)}.magicrc"]
if {[file exists $::sky130::pdk_rc]} {
    source $::sky130::pdk_rc
} else {
    puts ">>> rc_wrapper.tcl: PDK rc not found at $::sky130::pdk_rc"
}

namespace eval ::sky130 {
    variable targetGeom "1400x900+80+60"
}

proc ::sky130::has_tk {} {
    foreach c {wm bind after winfo} {
        if {[llength [info commands $c]] == 0} { return 0 }
    }
    return 1
}

if {[::sky130::has_tk]} {
    # Delay to allow window creation; then normalize geometry.
    after 120 {
        catch { wm attributes . -zoomed 0 }
        catch { wm attributes . -fullscreen 0 }
        catch { wm geometry . $::sky130::targetGeom }
        set sw [winfo screenwidth .]
        set sh [winfo screenheight .]
        catch { wm maxsize . [expr {$sw-120}] [expr {$sh-120}] }
        catch { wm title . "Magic ($env(PDK)) — SKY130" }
        catch { if {[winfo exists .console]} { wm geometry .console "+40+40" } }
    }
}
EOF
ok "rc wrapper written: $RC_FILE"

# Demo SPICE file (optional)
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

# ---------------------------- Launchers ------------------------------------
step "Install launchers"
sudo install -d -m 755 /usr/local/bin

# Common choose_pdk function text (to avoid duplication)
read -r -d '' CHOOSE_PDK <<'EOS' || true
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
EOS

# magic-sky130 (normal GL)
sudo tee /usr/local/bin/magic-sky130 >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
'"$CHOOSE_PDK"'
read -r PDK_ROOT PDK <<<"$(choose_pdk || true)"
[ -n "${PDK_ROOT:-}" ] || { echo "No SKY130 PDK found."; exit 1; }
MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic binary not found."; exit 1; }

RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"

# Ensure XQuartz is running and DISPLAY is sane
open -ga XQuartz || true
sleep 2
LDISP="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LDISP:-}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done
fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true

exec /usr/bin/env -i PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$HOME" SHELL="/bin/zsh" LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" \
  DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" \
  "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
sudo chmod +x /usr/local/bin/magic-sky130

# magic-sky130-xsafe (software GL)
sudo tee /usr/local/bin/magic-sky130-xsafe >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
'"$CHOOSE_PDK"'
read -r PDK_ROOT PDK <<<"$(choose_pdk || true)"
[ -n "${PDK_ROOT:-}" ] || { echo "No SKY130 PDK found."; exit 1; }
MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic binary not found."; exit 1; }

RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"

defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
open -ga XQuartz || true
sleep 2
LDISP="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LDISP:-}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done
fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true

export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

exec /usr/bin/env -i PATH="/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  HOME="$HOME" SHELL="/bin/zsh" LANG="en_US.UTF-8" LC_ALL="en_US.UTF-8" \
  DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" \
  LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
  "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
sudo chmod +x /usr/local/bin/magic-sky130-xsafe
ok "Launchers installed to /usr/local/bin (magic-sky130, magic-sky130-xsafe)"

# ---------------------------- Verify Magic headless ------------------------
step "Headless Magic tech-load check"
set +e
MP_BIN="$(command -v magic || true)"
if [ -z "$MP_BIN" ]; then die "magic not found in PATH after install."; fi
read -r PBASE PNAME <<<"$(pdk_loc)"
SMOKE_TCL="$WORKDIR/smoke.tcl"
cat > "$SMOKE_TCL" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
if /usr/bin/env -i PATH="$PATH" HOME="$HOME" PDK_ROOT="$PBASE" PDK="$PNAME" \
   "$MP_BIN" -norcfile -dnull -noconsole -T "$PNAME" -rcfile "$RC_DIR/rc_wrapper.tcl" "$SMOKE_TCL" \
   >"$LOGDIR/magic_headless.$ts.log" 2>&1; then
  ok "Magic headless tech load OK"
else
  warn "Magic headless tech load failed (see $LOGDIR/magic_headless.$ts.log)"
fi
set -e

# ---------------------------- Summary --------------------------------------
cat <<EOS

========================================================
Install complete.

Launch Magic:
  • magic-sky130
  • magic-sky130-xsafe   (software GL, if GPU drivers are crashy)

PDK env (auto-set by launchers):
  PDK_ROOT=$PBASE
  PDK=$PNAME

Demo:
  cd "$DEMO_DIR" && ngspice inverter_tt.spice

Full log:
  $LOG
========================================================
EOS

# End of script
