#!/usr/bin/env bash
# scripts/20_magic_brew.sh
# Install Magic via Homebrew (GUI with XQuartz), create a small env,
# and run headless + GUI smoke checks.
set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Config ----------
PREFIX="${PREFIX:-"$HOME/.eda/sky130"}"
BIN_DIR="$PREFIX/bin"
ACTIVATE="$PREFIX/activate"
LOG_DIR="$HOME/sky130-diag"
LOG="$LOG_DIR/magic_install.log"

# ---------- Helpers ----------
say(){ printf '%s\n' "$*"; }
info(){ say "[INFO] $*"; }
ok(){ say "✅ $*"; }
warn(){ say "⚠️  $*"; }
err(){ say "❌ $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || return 1; }

mkdir -p "$BIN_DIR" "$LOG_DIR"
: >"$LOG"

info "Using PREFIX: $PREFIX"
info "Logs: $LOG"

# ---------- 1) Homebrew presence ----------
if ! need brew; then
  err "Homebrew not found. Install it first:"
  say '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi
ok "Homebrew is available."

# ---------- 2) Install deps via brew ----------
info "Installing XQuartz (X11 server)…"
brew list --cask xquartz >/dev/null 2>&1 || brew install --cask xquartz | tee -a "$LOG"
ok "XQuartz installed (or already present)."

info "Installing Magic…"
brew list magic >/dev/null 2>&1 || brew install magic | tee -a "$LOG"
ok "Magic installed (or already present)."

# ---------- 3) Resolve magic binary ----------
MAGIC_BIN="$(command -v magic || true)"
if [[ -z "${MAGIC_BIN}" ]]; then
  # Try the canonical Homebrew path
  HB_BIN="$(brew --prefix)/bin/magic"
  if [[ -x "$HB_BIN" ]]; then
    MAGIC_BIN="$HB_BIN"
  fi
fi

if [[ -z "${MAGIC_BIN}" ]]; then
  err "Could not find a magic binary after install. Check Homebrew logs."
  exit 1
fi

info "Using magic binary: $MAGIC_BIN"

# ---------- 4) Create wrapper + env ----------
# wrapper (execs the brew magic to avoid PATH surprises)
WRAP="$BIN_DIR/magic"
cat >"$WRAP" <<EOF
#!/usr/bin/env bash
exec "$MAGIC_BIN" "\$@"
EOF
chmod +x "$WRAP"
ok "Wrapper created: $WRAP"

# simple activate file
cat >"$ACTIVATE" <<'EOF'
# ~/.eda/sky130/activate
# minimal environment for Sky130 tools
export PATH="$HOME/.eda/sky130/bin:$PATH"
# Prefer letting XQuartz set DISPLAY; uncomment only if needed:
# export DISPLAY=:0
EOF

ok "Activate file written: $ACTIVATE"
say 'To use:  source "$HOME/.eda/sky130/activate"'

# ---------- 5) Headless sanity (no GUI) ----------
info "Headless sanity check…"
SMOKE="$(mktemp /tmp/magic_smoke.XXXXXX.tcl)"
cat >"$SMOKE" <<'EOF'
# tiny Tcl: print tech name then quit
puts "tech=[tech name]"
quit -noprompt
EOF

if ! "$WRAP" -dnull -noconsole -rcfile /dev/null "$SMOKE" >>"$LOG" 2>&1; then
  warn "Headless check failed. See $LOG"
else
  ok "Headless OK (see $LOG)."
fi
rm -f "$SMOKE"

# ---------- 6) Start XQuartz & GUI smoke ----------
info "Starting/refreshing XQuartz…"
# launch (idempotent); give it a moment
open -ga XQuartz || true
sleep 1
# allow local client (if xhost exists)
if command -v xhost >/dev/null 2>&1; then
  xhost +localhost >/dev/null 2>&1 || true
fi

GUI_TCL="$(mktemp /tmp/magic_gui.XXXXXX.tcl)"
cat >"$GUI_TCL" <<'EOF'
# open default layout window and quit shortly after
after 600 { quit -noprompt }
EOF

# try drivers in order; stop at first success
drivers=(X11 XR OGL)
GUI_OK=0
for d in "${drivers[@]}"; do
  info "Trying GUI driver: -d $d …"
  if "$WRAP" -d "$d" -noconsole -rcfile /dev/null "$GUI_TCL" >>"$LOG" 2>&1; then
    ok "GUI launched with driver: $d (quick-open test)."
    GUI_OK=1
    break
  else
    warn "$d failed; trying next…"
  fi
done
rm -f "$GUI_TCL"

if [[ $GUI_OK -eq 0 ]]; then
  warn "All GUI drivers failed to quick-open. See log: $LOG"
  say "You can still try manually:  magic -d X11   (or XR / OGL)"
else
  ok "Magic GUI smoke test passed."
fi

say
ok "Done. Next steps:"
say '  1) source "$HOME/.eda/sky130/activate"'
say '  2) run: magic -d X11      # or: -d XR, -d OGL'
say "Log: $LOG"
