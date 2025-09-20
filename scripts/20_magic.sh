#!/usr/bin/env bash
# Magic GUI smoke test with XQuartz diagnostics and driver fallbacks
# Usage:
#   bash scripts/25_magic_gui_test.sh
#   MAGIC_DRIVER=XR bash scripts/25_magic_gui_test.sh   # force a specific driver
set -euo pipefail
IFS=$'\n\t'

# ---------- helpers ----------
log(){ printf "%s %s\n" "[$(date +%H:%M:%S)]" "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- env ----------
: "${EDA_ROOT:=$HOME/.eda/sky130}"
: "${MAGIC_BIN:=$EDA_ROOT/opt/magic/bin/magic}"
: "${MAGIC_DRIVER:=auto}"     # auto | XR | X11 | cairo | Tk
: "${XQUARTZ_APP:=XQuartz}"

# ---------- sanity: magic present ----------
if [ ! -x "$MAGIC_BIN" ]; then
  echo "[ERR] Magic binary not found at $MAGIC_BIN"
  echo "      Run: bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Madrock9604/sky130_MacOS/main/scripts/20_magic.sh)\""
  exit 2
fi

# ---------- XQuartz settings & launch ----------
log "Ensuring XQuartz settings (Allow network clients, IGLX)…"
defaults write org.xquartz.X11 nolisten_tcp -bool false || true
defaults write org.xquartz.X11 enable_iglx -bool true || true

log "Restarting XQuartz…"
pkill -x "$XQUARTZ_APP" >/dev/null 2>&1 || true
open -a "$XQUARTZ_APP"
sleep 1

# ---------- probe display ----------
if have /opt/X11/bin/xdpyinfo; then
  if ! /opt/X11/bin/xdpyinfo >/dev/null 2>&1; then
    log "XQuartz display not ready yet; retrying once…"
    sleep 1
    /opt/X11/bin/xdpyinfo >/dev/null 2>&1 || {
      echo "[ERR] XQuartz isn't accepting X11 clients yet."
      echo "     Try fully quitting XQuartz (Cmd+Q) and rerun this script."
      exit 3
    }
  fi
fi
log "XQuartz display looks OK."

# ---------- choose driver(s) ----------
DRIVERS=()
case "$MAGIC_DRIVER" in
  auto)  DRIVERS=(XR X11 cairo Tk) ;;
  XR|X11|cairo|Tk) DRIVERS=("$MAGIC_DRIVER") ;;
  *) echo "[ERR] Unknown MAGIC_DRIVER='$MAGIC_DRIVER'"; exit 4 ;;
esac

# ---------- run headless quick check (confidence) ----------
if ! echo 'quit' | "$MAGIC_BIN" -dnull -noconsole -rcfile /dev/null >/dev/null 2>&1; then
  echo "[ERR] Magic headless check failed; GUI will likely fail too."
  exit 5
fi
log "Magic headless check passed."

# ---------- try GUI drivers ----------
for drv in "${DRIVERS[@]}"; do
  log "Trying Magic with driver: -d $drv …"
  if "$MAGIC_BIN" -d "$drv" >/dev/null 2>&1 & then
    pid=$!
    sleep 2
    if ps -p "$pid" >/dev/null 2>&1; then
      log "Magic GUI started with -d $drv (pid $pid)."
      echo "Type ':quit' in the Magic console to exit."
      exit 0
    fi
  fi
  log "Driver -d $drv failed to launch cleanly; trying next…"
done

# ---------- all failed ----------
echo "[ERR] Magic GUI failed with drivers: ${DRIVERS[*]}"
echo "Tips:"
echo "  • Reboot once after first installing XQuartz."
echo "  • Run: conda deactivate    (Conda can interfere with Tk on macOS)"
echo "  • Then rerun: MAGIC_DRIVER=Tk bash scripts/25_magic_gui_test.sh"
echo "  • If still failing, paste the output of:"
echo "      /opt/X11/bin/xdpyinfo | head -n5"
echo "      otool -L \"$MAGIC_BIN\" | egrep 'X11|Tcl|Tk'"
exit 6
