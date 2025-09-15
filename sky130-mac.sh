#!/usr/bin/env bash
# sky130-magic-mac.sh
# Robust macOS installer for Magic + SKY130 PDK with resilient XQuartz repair.
# Works on Apple Silicon and Intel, macOS 12/13/14/15 (Monterey/Ventura/Sonoma/Sequoia).

set -euo pipefail

# -------------------- Config & Logging --------------------
WORKDIR="${HOME}/.eda-bootstrap"
LOGDIR="${WORKDIR}/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOGDIR}/install.${STAMP}.log"
PDK_PREFIX="/opt/pdk"
MACPORTS_PREFIX="/opt/local"

mkdir -p "${LOGDIR}"
exec > >(tee -a "${LOG}") 2>&1

# Progress UI
TOTAL_STEPS=11
STEP=0
bar() {
  local width=30 done=$(( STEP*width/TOTAL_STEPS )) rest=$(( width-done ))
  printf "[%s%s] (%d/%d) %s\n" "$(printf '%0.s#' $(seq 1 $done))" "$(printf '%0.s.' $(seq 1 $rest))" "${STEP}" "${TOTAL_STEPS}" "$1"
}
next() { STEP=$((STEP+1)); bar "$1"; }
ok()   { printf "OK: %s\n" "$1"; }
warn() { printf "WARN: %s\n" "$1"; }
die()  { printf "ERROR: %s\nSee log: %s\n" "$1" "$LOG"; exit 1; }

say()  { printf -- "---- %s ----\n" "$1"; }

echo
say "Log file: ${LOG}"

# Ensure PATH
ensure_path() {
  export PATH="${MACPORTS_PREFIX}/bin:${MACPORTS_PREFIX}/sbin:/opt/X11/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
}

# -------------------- Xcode CLT --------------------
next "Check Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode CLT present: $(xcode-select -p)"
else
  warn "Xcode CLT missing. Opening Apple installer dialog…"
  xcode-select --install || true
  # Wait up to ~2 minutes for user to accept install (loops silently)
  for _ in $(seq 1 24); do
    sleep 5
    if xcode-select -p >/dev/null 2>&1; then
      ok "Xcode CLT installed"
      break
    fi
  done
  xcode-select -p >/dev/null 2>&1 || die "Xcode CLT not installed (rerun after installing from the Apple dialog)."
fi

# -------------------- MacPorts Install/Verify --------------------
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
  curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/${PKG}" -o "${WORKDIR}/${PKG}" || die "Failed to download MacPorts pkg"
  sudo installer -pkg "${WORKDIR}/${PKG}" -target / || die "MacPorts installer failed"
  ensure_path
fi

# Selfupdate / ports tree
if sudo "${MACPORTS_PREFIX}/bin/port" -q selfupdate; then
  ok "MacPorts selfupdate complete"
else
  die "MacPorts selfupdate failed"
fi

# Final CLI check
macports_ok || die "MacPorts not functional after install"

# -------------------- XQuartz (install/repair/verify) --------------------
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
  local APP
  APP="$(_xq_app)"
  if [ -z "${APP}" ]; then
    mkdir -p "${WORKDIR}"
    curl -fsSL https://api.github.com/repos/XQuartz/XQuartz/releases/latest -o "${WORKDIR}/xq.json" || return 1
    local PKG_URL
    PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' "${WORKDIR}/xq.json" || true)"
    [ -n "${PKG_URL}" ] || return 1
    say "Downloading XQuartz…"
    curl -fL "${PKG_URL}" -o "${WORKDIR}/XQuartz.pkg" || return 1
    sudo installer -pkg "${WORKDIR}/XQuartz.pkg" -target / || return 1
    APP="$(_xq_app)"
  fi

  # Friendly prefs & quarantine clear (only app + /opt/X11)
  defaults write org.xquartz.X11 enable_iglx -bool true >/dev/null 2>&1 || true
  sudo xattr -dr com.apple.quarantine "${APP}" /opt/X11 >/dev/null 2>&1 || true

  # First launch
  open -ga "${APP}" || true
  sleep 4

  local DISP
  DISP="$(_xq_pick_display)"; export DISPLAY="${DISP}"
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

  if /opt/X11/bin/xset -q >/div/null 2>&1; then
    ok "XQuartz repaired (DISPLAY=${DISPLAY})"
    return 0
  fi

  # Try kickstarting the agent
  launchctl kickstart -kp "gui/$UID/org.xquartz.X11" 2>/dev/null || true
  sleep 3
  /opt/X11/bin/xset -q >/dev/null 2>&1 && { ok "XQuartz agent started (DISPLAY=${DISPLAY})"; return 0; }

  return 1
}

if ensure_xquartz; then
  :
else
  die "XQuartz/X11 failed to start. Open XQuartz once from /Applications (accept prompts), then rerun."
fi

# -------------------- Magic via MacPorts --------------------
next "Install Magic (+x11)"
ensure_path

# Make sure Tk uses X11 variant
sudo port -N upgrade --enforce-variants tk +x11 >/dev/null 2>&1 || true
sudo port -N install  --enforce-variants tk +x11

# Magic (force X11, not Aqua)
sudo port -N upgrade --enforce-variants magic +x11 -quartz >/dev/null 2>&1 || true
sudo port -N install  --enforce-variants magic +x11 -quartz

MAGIC_BIN="$(command -v magic || true)"
[ -x "${MAGIC_BIN:-/dev/null}" ] || die "Magic binary not found after MacPorts install"
ok "Magic at ${MAGIC_BIN}"

# -------------------- Verify Magic (headless) --------------------
next "Verify Magic (headless tech load)"
# basic version
"${MAGIC_BIN}" -v || true

# -------------------- SKY130 PDK via open_pdks --------------------
next "Install SKY130 PDK (open_pdks)"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
if [ -d open_pdks/.git ]; then
  (cd open_pdks && git pull --rebase)
else
  git clone https://github.com/RTimothyEdwards/open_pdks.git
fi
cd open_pdks
./configure --prefix="${PDK_PREFIX}" --enable-sky130-pdk --with-sky130-local-path="${PDK_PREFIX}" --enable-sram-sky130
make -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
sudo make install

# Detect PDK
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

# Try a quick headless load with tech
cat > "${WORKDIR}/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
/usr/bin/env -i PATH="${PATH}" HOME="${HOME}" PDK_ROOT="${PBASE}" PDK="${PNAME}" \
  "${MAGIC_BIN}" -norcfile -dnull -noconsole -T "${PNAME}" "${WORKDIR}/smoke.tcl" >/dev/null 2>&1 \
  && ok "Magic
