#!/usr/bin/env bash
# sky130-mac.sh — macOS bootstrap for Magic + SKY130 PDK
# - Verifies Xcode CLT
# - Installs/repairs MacPorts (auto-picks correct .pkg for your macOS)
# - Installs/repairs XQuartz & X11 (DISPLAY wiring, socket checks, prefs reset)
# - Installs Magic (MacPorts, +x11 variant) and deps
# - Installs SKY130 PDK via open_pdks into /opt/pdk
# - Creates handy launchers: magic-sky130 and magic-sky130-xsafe
# - Logs everything to ~/.eda-bootstrap/logs/install.<timestamp>.log
#
# Tested on macOS Monterey/Ventura/Sonoma/Sequoia (Intel + Apple Silicon)

set -Eeuo pipefail

### --- Globals & Paths ---
MACPORTS_PREFIX="/opt/local"
PDK_PREFIX="/opt/pdk"
WORKDIR="${HOME}/.eda-bootstrap"
LOGDIR="${WORKDIR}/logs"
TS="$(date +%Y%m%d-%H%M%S)"
LOGFILE="${LOGDIR}/install.${TS}.log"
RC_DIR="${HOME}/.config/sky130"
DEMO_DIR="${HOME}/sky130-demo"

TOTAL_STEPS=9
STEP=0

mkdir -p "${LOGDIR}" "${RC_DIR}" "${DEMO_DIR}"

### --- Pretty printing & logging helpers ---
say()  { printf "%s\n" "$*" | tee -a "${LOGFILE}"; }
ok()   { printf "✔ %s\n" "$*" | tee -a "${LOGFILE}"; }
warn() { printf "✱ %s\n" "$*" | tee -a "${LOGFILE}"; }
die()  { printf "✖ %s\n" "$*" | tee -a "${LOGFILE}"; exit 1; }

step() {
  STEP=$((STEP+1))
  printf "\n[%d/%d] %s\n" "${STEP}" "${TOTAL_STEPS}" "$*" | tee -a "${LOGFILE}"
}

run() {
  # run "desc" cmd...
  local desc="$1"; shift
  printf "→ %s\n" "${desc}" | tee -a "${LOGFILE}"
  {
    printf "\n--- %s ---\n" "${desc}"
    "$@"
    rc=$?
    printf "--- exit %s: %s ---\n" "${rc}" "${desc}"
    exit "${rc}"
  } >>"${LOGFILE}" 2>&1
}

ensure_path() {
  # Avoid stomping user PATH, just make sure MacPorts/X11 are visible
  export PATH="${MACPORTS_PREFIX}/bin:${MACPORTS_PREFIX}/sbin:/opt/X11/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
}

require_sudo() {
  if ! sudo -vn >/dev/null 2>&1; then
    say "Requesting sudo (needed for installers)…"
    sudo -v || die "Cannot proceed without sudo."
  fi
}

### --- Xcode CLT ---
check_xcode() {
  step "Check Xcode Command Line Tools"
  if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode CLT found: $(xcode-select -p)"
  else
    warn "Xcode CLT not found. Triggering Apple installer popup…"
    run "xcode-select --install" xcode-select --install || true
    if xcode-select -p >/dev/null 2>&1; then
      ok "Xcode CLT installed"
    else
      die "Xcode CLT not installed. Open the popup, finish install, then re-run this script."
    fi
  fi
}

### --- MacPorts install/verify ---
macos_pkg_suffix() {
  # Prints the OS suffix used by MacPorts release PKGs
  local maj
  maj="$(sw_vers -productVersion | awk -F. '{print $1}')"
  case "${maj}" in
    12) echo "12-Monterey" ;;
    13) echo "13-Ventura"  ;;
    14) echo "14-Sonoma"   ;;
    15) echo "15-Sequoia"  ;;
    *)  die "Unsupported macOS $(sw_vers -productVersion). Need 12–15." ;;
  esac
}

macports_ok() {
  /usr/bin/env -i PATH="${MACPORTS_PREFIX}/bin:${MACPORTS_PREFIX}/sbin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="${HOME}" "${MACPORTS_PREFIX}/bin/port" version >/dev/null 2>&1
}

install_macports() {
  step "Install/Repair MacPorts"
  ensure_path
  if command -v port >/dev/null 2>&1; then
    if macports_ok; then
      run "MacPorts selfupdate" sudo port -N -v selfupdate || true
      ok "MacPorts present: $(port version | tr -d '\n')"
      return
    fi
    warn "MacPorts is present but not working. Attempting repair via selfupdate…"
    run "MacPorts repair selfupdate" sudo "${MACPORTS_PREFIX}/bin/port" -N -v selfupdate || true
    if macports_ok; then ok "MacPorts repaired"; return; fi
  fi

  require_sudo
  mkdir -p "${WORKDIR}"
  local os suf url fallback
  suf="$(macos_pkg_suffix)"
  # Try GitHub latest first
  url="$(curl -fsSL https://api.github.com/repos/macports/macports-base/releases/latest \
        | awk -F\" '/browser_download_url/ && /MacPorts-.*-'"${suf}"'\.pkg/ {print $4; exit}')"
  # Fallback to a known recent version if GitHub API blocked
  fallback="https://distfiles.macports.org/MacPorts/MacPorts-2.11.5-${suf}.pkg"
  [ -n "${url}" ] || url="${fallback}"

  say "Downloading MacPorts pkg for ${suf}…"
  run "Fetch MacPorts pkg" curl -fL "${url}" -o "${WORKDIR}/MacPorts-${suf}.pkg"
  run "Install MacPorts" sudo installer -pkg "${WORKDIR}/MacPorts-${suf}.pkg" -target /

  ensure_path
  run "MacPorts first selfupdate" sudo port -N -v selfupdate || true
  if macports_ok; then
    ok "MacPorts installed and responding: $(port version | tr -d '\n')"
  else
    die "MacPorts not functional after install. See ${LOGFILE}"
  fi
}

### --- XQuartz / X11 ensure & repair ---
xq_app_path() {
  if [ -d "/Applications/Utilities/XQuartz.app" ]; then
    printf "/Applications/Utilities/XQuartz.app\n"
  elif [ -d "/Applications/XQuartz.app" ]; then
    printf "/Applications/XQuartz.app\n"
  else
    printf "\n"
  fi
}
xq_socket() {
  # return first live XQuartz socket; else empty
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && { printf '%s\n' "$d/org.xquartz:0"; return; }
  done
  printf "\n"
}
xq_display() {
  local D
  D="$(launchctl getenv DISPLAY 2>/dev/null || true)"
  if [ -n "${D}" ]; then printf "%s\n" "${D}"; return; fi
  D="$(xq_socket)"
  if [ -n "${D}" ]; then printf "%s\n" "${D}"; return; fi
  printf ":0\n"
}
xq_env_export() {
  local D; D="$(xq_display)"
  export DISPLAY="${D}"
  launchctl setenv DISPLAY "${D}" >/dev/null 2>&1 || true
}
xquartz_running() { pgrep -x XQuartz >/dev/null 2>&1; }

install_xquartz() {
  require_sudo
  local url
  url="$(curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest \
        | awk -F\" '/browser_download_url/ && /\.pkg/ {print $4; exit}')"
  [ -n "${url}" ] || die "Could not determine XQuartz pkg URL."
  say "Downloading XQuartz…"
  run "Fetch XQuartz pkg" curl -fL "${url}" -o "${WORKDIR}/XQuartz.pkg"
  run "Install XQuartz" sudo installer -pkg "${WORKDIR}/XQuartz.pkg" -target /
}

repair_xquartz() {
  # a safe, minimal-but-effective repair: nuke prefs/cache + restart app, rewire DISPLAY
  say "Repairing XQuartz/X11…"
  run "Kill XQuartz" pkill -x XQuartz || true
  defaults delete org.xquartz.X11 >/dev/null 2>&1 || true
  rm -f "${HOME}/Library/Preferences/org.xquartz.X11.plist" || true
  rm -rf "${HOME}/Library/Caches/org.xquartz.X11" || true
  rm -f "${HOME}/.Xauthority" "${HOME}/.serverauth."* 2>/dev/null || true
  defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true

  # Relaunch and wire DISPLAY
  open -ga XQuartz || true
  sleep 4
  xq_env_export
  /opt/X11/bin/xhost +SI:localuser:"${USER}" >/dev/null 2>&1 || true
}

ensure_xquartz() {
  step "Ensure/Repair XQuartz & X11"
  if [ -z "$(xq_app_path)" ] || [ ! -x "/opt/X11/bin/xset" ]; then
    warn "XQuartz missing or incomplete; installing…"
    install_xquartz
  fi

  # Start + sanity
  open -ga XQuartz || true
  sleep 3
  xq_env_export
  /opt/X11/bin/xhost +SI:localuser:"${USER}" >/dev/null 2>&1 || true

  if ! /opt/X11/bin/xset -q >/dev/null 2>&1; then
    warn "xset -q failed; attempting repair…"
    repair_xquartz
  fi

  if /opt/X11/bin/xset -q >/dev/null 2>&1; then
    ok "XQuartz/X11 OK (DISPLAY=$(xq_display))"
  else
    # One last attempt: full re-install + repair
    warn "Deep repair: reinstall XQuartz and rewire DISPLAY…"
    install_xquartz
    repair_xquartz
    if /opt/X11/bin/xset -q >/dev/null 2>&1; then
      ok "XQuartz recovered (DISPLAY=$(xq_display))"
    else
      die "XQuartz could not open a display. Try logging out/in, then re-run. See ${LOGFILE}"
    fi
  fi
}

### --- MacPorts: install Magic (+x11) & deps ---
ensure_port() {
  # ensure_port <portname> [variants...]
  local name="$1"; shift || true
  if port installed "${name}" >/dev/null 2>&1; then
    run "port upgrade --enforce-variants ${name} $*" sudo port -N upgrade --enforce-variants "${name}" "$@"
  else
    run "port install ${name} $*" sudo port -N install "${name}" "$@"
  fi
}

install_magic_ports() {
  step "Install Magic (+x11) and tools via MacPorts"
  ensure_path
  run "Update ports tree" sudo port -N -v sync || true

  # Ensure Tk & Magic are X11 builds (not quartz)
  ensure_port tk +x11
  ensure_port magic +x11

  # Handy tools (optional)
  run "Install common EDA tools" sudo port -N install ngspice netgen gawk wget tcl tk git || true

  if command -v magic >/dev/null 2>&1; then
    ok "Magic installed: $(magic -version 2>/dev/null | head -n1 || echo from MacPorts)"
  else
    die "Magic is not available on PATH after install."
  fi
}

### --- SKY130 PDK via open_pdks ---
install_pdk() {
  step "Install SKY130 PDK (open_pdks → ${PDK_PREFIX})"
  require_sudo
  sudo install -d -m 755 "${PDK_PREFIX}"
  sudo chown "$(id -u)":"$(id -g)" "${PDK_PREFIX}" || true

  mkdir -p "${WORKDIR}"
  cd "${WORKDIR}"

  if [ -d open_pdks/.git ]; then
    run "Update open_pdks" bash -lc "cd open_pdks && git pull --rebase"
  else
    run "Clone open_pdks" git clone https://github.com/RTimothyEdwards/open_pdks.git
  fi

  cd open_pdks
  run "Configure open_pdks" ./configure \
    --prefix="${PDK_PREFIX}" \
    --enable-sky130-pdk \
    --with-sky130-local-path="${PDK_PREFIX}" \
    --enable-sram-sky130
  run "Build open_pdks" make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  run "Install open_pdks" sudo make install

  # Verify
  if [ -f "${PDK_PREFIX}/sky130A/libs.tech/magic/sky130A.magicrc" ] || \
     [ -f "${PDK_PREFIX}/share/pdk/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    ok "SKY130 PDK installed"
  else
    die "SKY130 PDK not detected under ${PDK_PREFIX}. See ${LOGFILE}"
  fi
}

### --- Write rc wrapper + demo + launchers ---
write_rc_and_demo() {
  step "Write demo and rc wrapper"
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

  ok "Demo + rc wrapper ready"
}

install_launchers() {
  step "Install launchers"
  require_sudo
  sudo install -d -m 755 /usr/local/bin

  sudo tee /usr/local/bin/magic-sky130 >/dev/null <<'EOF'
#!/bin/sh
set -eu
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }
# Ensure XQuartz is running and DISPLAY wired
pgrep -x XQuartz >/dev/null 2>&1 || { open -ga XQuartz || true; sleep 3; }
LDISP="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LDISP:-}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done
fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true

MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic binary not found"; exit 1; }

read PDK_ROOT PDK <<EOF2
$(choose_pdk || true)
EOF2
[ -n "${PDK_ROOT:-}" ] || { echo "No SKY130 PDK found under /opt or /usr/local"; exit 1; }

RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"

exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" \
  "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
  sudo chmod +x /usr/local/bin/magic-sky130

  sudo tee /usr/local/bin/magic-sky130-xsafe >/dev/null <<'EOF'
#!/bin/sh
set -eu
defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
pkill -x XQuartz 2>/dev/null || true
open -ga XQuartz || true
sleep 4
LDISP="$(launchctl getenv DISPLAY 2>/dev/null || true)"
if [ -z "${LDISP:-}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do [ -S "$d/org.xquartz:0" ] && { LDISP="$d/org.xquartz:0"; break; }; done
fi
export DISPLAY="${LDISP:-:0}"
/opt/X11/bin/xhost +SI:localuser:"$USER" >/dev/null 2>&1 || true
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe

choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk /usr/local/share/pdk; do
  for n in sky130A sky130B; do [ -d "$b/$n" ] && { printf '%s %s\n' "$b" "$n"; return 0; }; done
done; return 1; }

MAGIC_BIN="/opt/local/bin/magic"; [ -x "$MAGIC_BIN" ] || MAGIC_BIN="/usr/local/bin/magic"
[ -x "$MAGIC_BIN" ] || { echo "magic binary not found"; exit 1; }

read PDK_ROOT PDK <<EOF2
$(choose_pdk || true)
EOF2
[ -n "${PDK_ROOT:-}" ] || { echo "No SKY130 PDK found"; exit 1; }

RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [ -f "$RC_WRAPPER" ] && RC="$RC_WRAPPER"

exec /usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK" LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
  "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
  sudo chmod +x /usr/local/bin/magic-sky130-xsafe

  ok "Launchers installed (magic-sky130, magic-sky130-xsafe)"
}

### --- Headless sanity check (tech load) ---
magic_headless_check() {
  step "Headless sanity check (Magic loads SKY130 tech)"
  local MP RCFILE PBASE PNAME
  MP="$(command -v magic || true)"
  [ -x "${MP:-/dev/null}" ] || die "magic not found on PATH"

  # find PDK
  if [ -f "${PDK_PREFIX}/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    PBASE="${PDK_PREFIX}"; PNAME="sky130A"
  elif [ -f "${PDK_PREFIX}/share/pdk/sky130A/libs.tech/magic/sky130A.magicrc" ]; then
    PBASE="${PDK_PREFIX}/share/pdk"; PNAME="sky130A"
  else
    die "SKY130 PDK rc not found after install."
  fi

  RCFILE="${RC_DIR}/rc_wrapper.tcl"
  echo 'puts ">>> smoke: tech=[tech name]"; quit -noprompt' > "${WORKDIR}/smoke.tcl"

  /usr/bin/env -i PATH="${PATH}" HOME="${HOME}" PDK_ROOT="${PBASE}" PDK="${PNAME}" \
    "${MP}" -norcfile -dnull -noconsole -T "${PNAME}" -rcfile "${RCFILE}" "${WORKDIR}/smoke.tcl" \
    >>"${LOGFILE}" 2>&1 || true

  if grep -q ">>> smoke: tech=" "${LOGFILE}"; then
    ok "Magic loaded tech '${PNAME}' (headless)"
  else
    die "Magic headless tech check failed. See ${LOGFILE}"
  fi
}

### --- MAIN ---
main() {
  say "---- Log file: ${LOGFILE} ----"
  ensure_path
  check_xcode
  install_macports
  ensure_xquartz
  install_magic_ports
  install_pdk
  write_rc_and_demo
  install_launchers
  magic_headless_check

  say ""
  ok "All done 🎉"
  say "Launch Magic:"
  say "  • magic-sky130           # normal GUI"
  say "  • magic-sky130-xsafe     # GUI with software GL (safer on finicky GPUs)"
  say ""
  say "Logs saved to: ${LOGFILE}"
  say "Demo:  cd \"${DEMO_DIR}\" && ngspice inverter_tt.spice"
}
main "$@"
