#!/usr/bin/env bash
# scripts/99_magic_gui_probe.sh
# Probe Magic headless first, then try GUI drivers with a tiny Tcl script.
set -euo pipefail

LOGDIR="${HOME}/sky130-diag"
LOG="${LOGDIR}/magic_gui_attempt.log"
mkdir -p "$LOGDIR"
: >"$LOG"

say(){ printf '%s\n' "$*" | tee -a "$LOG"; }

# 0) Try to import your environment if present (but don't require it)
ACT="${HOME}/.eda/sky130/activate"
if [ -f "$ACT" ]; then
  # shellcheck disable=SC1090
  . "$ACT" || true
fi

# 1) Find magic
MAGIC_BIN="${MAGIC_BIN:-$(command -v magic || true)}"
if [ -z "${MAGIC_BIN}" ]; then
  for c in /opt/local/bin/magic /opt/homebrew/bin/magic /usr/local/bin/magic; do
    [ -x "$c" ] && MAGIC_BIN="$c" && break
  done
fi
if [ -z "${MAGIC_BIN:-}" ]; then
  say "❌ Could not find 'magic' in PATH. Install it (brew or MacPorts) and re-run."
  exit 1
fi
say "[INFO] Using magic: ${MAGIC_BIN}"
"$MAGIC_BIN" -v || "$MAGIC_BIN" -version || true | tee -a "$LOG"

# 2) Headless sanity check using a tiny Tcl file
SMOKE="${LOGDIR}/smoke.tcl"
cat >"$SMOKE" <<'EOF'
puts "OK [tech name]"
quit -noprompt
EOF

say "[INFO] Headless sanity check…"
if ! "$MAGIC_BIN" -dnull -noconsole "$SMOKE" >>"$LOG" 2>&1; then
  say "❌ Headless tech load failed; see $LOG"
  exit 1
fi
say "✅ Headless OK."

# 3) Ensure XQuartz is up & DISPLAY set (best effort; no failure if missing)
if ! pgrep -x XQuartz >/dev/null 2>&1; then
  say "[INFO] Starting XQuartz…"
  open -a XQuartz || true
  sleep 1
fi
if [ -z "${DISPLAY:-}" ]; then
  export DISPLAY=":0"
  say "[INFO] DISPLAY not set; using ${DISPLAY}"
fi
# Allow local client (ignore errors if xhost not present yet)
if command -v xhost >/dev/null 2>&1; then
  /usr/X11/bin/xhost +localhost >/dev/null 2>&1 || true
fi

# 4) Try GUI drivers, each for ~1s, then quit
GUI_TCL="${LOGDIR}/gui_probe.tcl"
cat >"$GUI_TCL" <<'EOF'
# open a tiny delay to ensure window creation, then exit
after 1000 { quit -noprompt }
EOF

drivers=(X11 CAIRO OGL XR)   # try in this order
ok_driver=""
for d in "${drivers[@]}"; do
  say "[INFO] Trying GUI driver: -d ${d} …"
  if "$MAGIC_BIN" -d "$d" -noconsole -rcfile /dev/null "$GUI_TCL" >>"$LOG" 2>&1; then
    ok_driver="$d"
    say "✅ GUI driver works: ${d}"
    break
  else
    say "↩︎ ${d} failed; trying next…"
  fi
done

if [ -z "$ok_driver" ]; then
  say "❌ All GUI drivers failed. See log: $LOG"
  exit 2
fi

say ""
say "🎉 Success. Launch Magic GUI with:"
say "    ${MAGIC_BIN} -d ${ok_driver}"
say ""
say "(Full log: $LOG)"
