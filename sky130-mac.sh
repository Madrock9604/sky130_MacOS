# Save as sky130-mac.sh
# Then:  chmod +x sky130-mac.sh && ./sky130-mac.sh

#!/usr/bin/env bash
# sky130-mac.sh — Magic + SKY130 on macOS (Monterey/Ventura/Sonoma/Sequoia)
set -euo pipefail

WORKDIR="${HOME}/.eda-bootstrap"
LOGDIR="${WORKDIR}/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOGDIR}/install.${STAMP}.log"
PDK_PREFIX="/opt/pdk"
MACPORTS_PREFIX="/opt/local"

mkdir -p "${LOGDIR}"
exec > >(tee -a "${LOG}") 2>&1

TOTAL_STEPS=11
STEP=0

bar() {
  # Robust progress bar (no seq; safe with set -u)
  local msg="${1:-}"
  local width=30
  local done=$(( STEP * width / TOTAL_STEPS ))
  (( done < 0 )) && done=0
  (( done > width )) && done=$width
  local rest=$(( width - done ))
  # Build bar
  local hashes dots
  hashes="$(printf '%*s' "${done}" '' | tr ' ' '#')"
  dots="$(printf '%*s' "${rest}" '' | tr ' ' '.')"
  printf "[%s%s] (%d/%d) %s\n" "${hashes}" "${dots}" "${STEP}" "${TOTAL_STEPS}" "${msg}"
}
next(){ STEP=$((STEP+1)); bar "$1"; }
ok(){   printf "OK: %s\n" "$1"; }
warn(){ printf "WARN: %s\n" "$1"; }
die(){  printf "ERROR: %s\nSee log: %s\n" "$1" "$LOG"; exit 1; }
say(){  printf -- "---- %s ----\n" "$1"; }

echo
say "Log file: ${LOG}"

ensure_path() {
  export PATH="${MACPORTS_PREFIX}/bin:${MACPORTS_PREFIX}/sbin:/opt/X11/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
}

# --- Xcode CLT ---
next "Check Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode CLT present: $(xcode-select -p)"
else
  warn "Xcode CLT missing. Opening installer dialog…"
  xcode-select --install || true
  for _ in $(seq 1 24); do
    sleep 5
    if xcode-select -p >/dev/null 2>&1; then ok "Xcode CLT installed"; break; fi
  done
  xcode-select -p >/dev/null 2>&1 || die "Xcode CLT not installed (accept Apple dialog, then rerun)."
fi

# --- MacPorts ---
next "Install/Verify MacPorts"
ensure_path

macports_ok() {
  /usr/bin/env -i PATH="${MACPORTS_PREFIX}/bin:${MACPORTS_PREFIX}/sbin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" "${MACPORTS_PREFIX}/bin/port" version >/dev/null 2>&1
}

if command -v port >/dev/null 2>&1 && macports_ok; then
  ok "MacPorts CLI ready"
else
  osmaj="$(sw_vers -productVersion | awk -F. '{print $1}')"
  case "${osmaj}" in
    15) PKG="MacPorts-2.11.5-15-Sequoia.pkg" ;;
    14) PKG="MacPorts-2.11.5-14-Sonoma.pkg" ;;
    13) PKG="MacPorts-2.11.5-13-Ventura.pkg" ;;
    12) PKG="MacPorts-2.11.5-12-Monterey.pkg" ;;
    *) die "Unsupported macOS major version: $(sw_vers -productVersion)" ;;
  esac
  mkdir -p "${WORKDIR}"
  say "Downloading MacPorts: ${PKG}"
  curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/${PKG}" -o "${WORKDIR}/${PKG}" || die "MacPorts download failed"
  sudo installer -pkg "${WORKDIR}/${PKG}" -target / || die "MacPorts installer failed"
  ensure_path
fi

sudo "${MACPORTS_PREFIX}/bin/port" -q selfupdate || die "MacPorts selfupdate failed"
macports_ok || die "MacPorts not functional after install"
ok "MacPorts ready"

# --- XQuartz ensure/repair ---
next "Ensure/Repair XQuartz + X11"

_xq_app() {
  if [ -d "/Applications/Utilities/XQuartz.app" ]; then printf '/Applications/Utilities/XQuartz.app\n'
  elif [ -d "/Applications/XQuartz.app" ]; then printf '/Applications/XQuartz.app\n'
  else printf '\n'; fi
}
_xq_pick_display() {
  local LD
  LD="$(launchctl getenv DISPLAY 2>/dev/null || true)"
  if [ -n "${LD}" ] && [ -S "${LD}" ]; then printf '%s\n' "${LD}" && return 0; fi
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && { printf '%s\n' "$d/org.xquartz:0"; return 0; }
  done
  printf ':0\n'
}
xquartz_hard_reset() {
  pkill -x XQuartz 2>/dev/null || true
  defaults delete org.xquartz.X11 >/dev/null 2>&1 || true
  rm -f "${HOME}/.Xauthority" "${HOME}/.serverauth."* 2>/dev/null || true
  rm -rf "${HOME}/Library/Caches/org.xquartz.X11" 2>/dev/null || true
}
ensure_xquartz() {
  local APP="$(_xq_app)"
  if [ -z "${APP}" ]; then
    mkdir -p "${WORKDIR}"
    # Try latest release from GitHub API
    if curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest -o "${WORKDIR}/xq.json"; then
      PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' "${WORKDIR}/xq.json" || true)"
    fi
    if [ -z "${PKG_URL:-}" ]; then
      # Fallback to known stable (adjust if needed later)
      PKG_URL="https://github.com/XQuartz/XQuartz/releases/download/XQuartz-2.8.5/XQuartz-2.8.5.pkg"
    fi
    say "Downloading XQuartz…"
    curl -fL "${PKG_URL}" -o "${WORKDIR}/XQuartz.pkg" || return 1
    sudo installer -pkg "${WORKDIR}/XQuartz.pkg" -target / || return 1
    APP="$(_xq_app)"
  fi

  defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
  sudo xattr -dr com.apple.quarantine "${APP}" /opt/X11 >/dev/null 2>&1 || true

  open -ga "${APP}" || true
  sleep 4
  local DISP="$(_xq_pick_display)"; export DISPLAY="${DISP}"
  launchctl setenv DISPLAY "${DISP}" >/dev/null 2>&1 || true
  /opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true

  if /opt/X11/bin/xset -q >/dev/null 2>&1; then
    ok "XQuartz running (DISPLAY=${DISPLAY})"
    return 0
  fi

  warn "XQuartz first launch failed; applying hard reset…"
  xquartz_hard_reset
  open -ga "${APP}" || true
  sleep 5
  DISP="$(_xq_pick_display)"; export DISPLAY="${DISP}"
  launchctl setenv DISPLAY "${DISP}" >/dev/null 2>&1 || true
  /opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true

  if /opt/X11/bin/xset -q >/dev/null 2>&1; then
    ok "XQuartz repaired (DISPLAY=${DISPLAY})"
    return 0
  fi

  launchctl kickstart -kp "gui/$UID/org.xquartz.X11" 2>/dev/null || true
  sleep 3
  /opt/X11/bin/xset -q >/dev/null 2>&1 && { ok "XQuartz agent started (DISPLAY=${DISPLAY})"; return 0; }

  return 1
}

ensure_xquartz || die "XQuartz/X11 failed to start. Open XQuartz once from /Applications (accept prompts), then rerun."

# --- Magic via MacPorts ---
next "Install Magic (+x11)"
ensure_path
sudo port -N upgrade --enforce-variants tk +x11 >/dev/null 2>&1 || true
sudo port -N install  --enforce-variants tk +x11
sudo port -N upgrade --enforce-variants magic +x11 -quartz >/dev/null 2>&1 || true
sudo port -N install  --enforce-variants magic +x11 -quartz
MAGIC_BIN="$(command -v magic || true)"
[ -x "${MAGIC_BIN:-/dev/null}" ] || die "Magic binary not found after MacPorts install"
ok "Magic at ${MAGIC_BIN}"

# --- Verify Magic headless ---
next "Verify Magic (headless tech load)"
"${MAGIC_BIN}" -v || true

# --- SKY130 PDK via open_pdks ---
next "Install SKY130 PDK (open_pdks)"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
if [ -d open_pdks/.git ]; then (cd open_pdks && git pull --rebase); else git clone https://github.com/RTimothyEdwards/open_pdks.git; fi
cd open_pdks
./configure --prefix="${PDK_PREFIX}" --enable-sky130-pdk --with-sky130-local-path="${PDK_PREFIX}" --enable-sram-sky130
make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
sudo make install

choose_pdk() {
  for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
    for n in sky130A sky130B; do
      [ -f "$b/$n/libs.tech/magic/${n}.magicrc" ] && { printf '%s %s\n' "$b" "$n"; return 0; }
    done
  done
  return 1
}
if read -r PBASE PNAME <<<"$(choose_pdk)"; then
  ok "SKY130 PDK found: ${PBASE}/${PNAME}"
else
  die "SKY130 PDK not detected after install"
fi

# Quick headless probe
cat > "${WORKDIR}/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
/usr/bin/env -i PATH="${PATH}" HOME="${HOME}" PDK_ROOT="${PBASE}" PDK="${PNAME}" \
  "${MAGIC_BIN}" -norcfile -dnull -noconsole -T "${PNAME}" "${WORKDIR}/smoke.tcl" >/dev/null 2>&1 \
  && ok "Magic headless tech load OK" || warn "Magic headless tech load failed (see log)"

# --- Demo + RC wrapper ---
next "Write demo and rc wrapper"
RC_DIR="${HOME}/.config/sky130"
DEMO_DIR="${HOME}/sky130-demo"
mkdir -p "${RC_DIR}" "${DEMO_DIR}"

cat > "${RC_DIR}/rc_wrapper.tcl" <<'EOF'
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

cat > "${DEMO_DIR}/inverter_tt.spice" <<'EOF'
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
ok "Demo + rc written"

# --- Launchers ---
next "Install launchers"
sudo install -d -m 755 /usr/local/bin

cat | sudo tee /usr/local/bin/magic-sky130 >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
if [ -d "/Applications/Utilities/XQuartz.app" ]; then APP="/Applications/Utilities/XQuartz.app"
elif [ -d "/Applications/XQuartz.app" ]; then APP="/Applications/XQuartz.app"
else APP=""; fi
pgrep -x XQuartz >/dev/null 2>&1 || { [ -n "$APP" ] && open -ga "$APP" || true; sleep 3; }
LD="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LD:-}" ] || [ ! -S "${LD}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LD="$d/org.xquartz:0"; break; }; done
  : "${LD:=:0}"
  export DISPLAY="$LD"; launchctl setenv DISPLAY "$LD" >/dev/null 2>&1 || true
fi
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
MAGIC_BIN="$(command -v magic || true)"; [ -x "${MAGIC_BIN:-}" ] || { echo "magic not found"; exit 1; }
read PDK_ROOT PDK <<<"$(choose_pdk || true)"; [ -n "${PDK_ROOT:-}" ] || { echo "No SKY130 PDK found"; exit 1; }
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
sudo chmod +x /usr/local/bin/magic-sky130

cat | sudo tee /usr/local/bin/magic-sky130-xsafe >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
if [ -d "/Applications/Utilities/XQuartz.app" ]; then APP="/Applications/Utilities/XQuartz.app"
elif [ -d "/Applications/XQuartz.app" ]; then APP="/Applications/XQuartz.app"
else APP=""; fi
defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
pkill -x XQuartz 2>/dev/null || true
[ -n "$APP" ] && open -ga "$APP" || true
sleep 4
LD="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LD:-}" ] || [ ! -S "${LD}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LD="$d/org.xquartz:0"; break; }; done
  : "${LD:=:0}"
  export DISPLAY="$LD"; launchctl setenv DISPLAY "$LD" >/dev/null 2>&1 || true
fi
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
MAGIC_BIN="$(command -v magic || true)"; [ -x "${MAGIC_BIN:-}" ] || { echo "magic not found"; exit 1; }
read PDK_ROOT PDK <<<"$(choose_pdk || true)"; [ -n "${PDK_ROOT:-}" ] || { echo "No SKY130 PDK found"; exit 1; }
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
sudo chmod +x /usr/local/bin/magic-sky130-xsafe
ok "Launchers installed"

# --- Final GUI probe ---
next "Quick GUI probe"
APP="$(_xq_app || true)"
[ -n "${APP}" ] && open -ga "${APP}" || true
sleep 2
/opt/X11/bin/xset -q >/dev/null 2>&1 || warn "X server didn't answer to xset (GUI may still come up)"
command -v magic-sky130 >/dev/null 2>&1 && ok "Try: magic-sky130  (or: magic-sky130-xsafe)"

# --- Summary ---
next "Done"
echo
say "Install complete"
echo "Log: ${LOG}"
echo "Launch:"
echo "  • magic-sky130           (GUI via X11)"
echo "  • magic-sky130-xsafe     (GUI with software OpenGL)"
echo
echo "SPICE demo:"
echo "  cd \"${HOME}/sky130-demo\" && ngspice inverter_tt.spice"
echo
