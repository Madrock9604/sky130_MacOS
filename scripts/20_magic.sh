#!/usr/bin/env bash
# scripts/20_magic_source.sh
# Build & install Magic from the official repo into ~/.eda/sky130
# Requires Homebrew (for XQuartz, tcl-tk, cairo). GUI via XQuartz.
set -Eeuo pipefail
IFS=$'\n\t'

# ---- Config ----
PREFIX="${PREFIX:-"$HOME/.eda/sky130"}"
OPT_DIR="$PREFIX/opt/magic"
BIN_DIR="$PREFIX/bin"
ACTIVATE="$PREFIX/activate"
LOG_DIR="$HOME/sky130-diag"
LOG="$LOG_DIR/magic_build.log"
SRC_DIR="${SRC_DIR:-"$HOME/gits"}"
MAGIC_GIT="${MAGIC_GIT:-"https://github.com/RTimothyEdwards/magic"}"
MAGIC_TAG="${MAGIC_TAG:-"master"}"   # set a tag like "8.3.552" if you want

say(){ printf '%s\n' "$*"; }
info(){ say "[INFO] $*"; }
ok(){ say "✅ $*"; }
warn(){ say "⚠️  $*"; }
err(){ say "❌ $*"; }
need(){ command -v "$1" >/dev/null 2>&1; }

mkdir -p "$BIN_DIR" "$OPT_DIR" "$LOG_DIR" "$SRC_DIR"
: >"$LOG"

info "Using PREFIX: $PREFIX"
info "Logs: $LOG"

# ---- 0) Homebrew present? ----
if ! need brew; then
  err "Homebrew not found. Install it first:"
  say '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi
ok "Homebrew is available."

# ---- 1) Deps via brew ----
info "Installing build/runtime deps (XQuartz, tcl-tk, cairo, pkg-config, git)…"
brew list --cask xquartz >/dev/null 2>&1 || brew install --cask xquartz | tee -a "$LOG"
brew list tcl-tk    >/dev/null 2>&1 || brew install tcl-tk     | tee -a "$LOG"
brew list cairo     >/dev/null 2>&1 || brew install cairo      | tee -a "$LOG"
brew list pkg-config>/dev/null 2>&1 || brew install pkg-config | tee -a "$LOG"
brew list git       >/dev/null 2>&1 || brew install git        | tee -a "$LOG"
ok "Deps installed (or already present)."

HB_PREFIX="$(brew --prefix)"
TCL_PREFIX="$(brew --prefix tcl-tk)"
CAIRO_PREFIX="$(brew --prefix cairo)"
X11_PREFIX="/opt/X11"

# ---- 2) Clone/Update Magic source ----
cd "$SRC_DIR"
if [[ -d magic/.git ]]; then
  info "Updating existing magic repo…"
  (cd magic && git fetch --all >>"$LOG" 2>&1 && git checkout "$MAGIC_TAG" >>"$LOG" 2>&1 && git pull >>"$LOG" 2>&1) || {
    err "Failed to update magic repo. See $LOG"; exit 1; }
else
  info "Cloning magic from $MAGIC_GIT …"
  git clone "$MAGIC_GIT" magic >>"$LOG" 2>&1 || { err "git clone failed"; exit 1; }
  (cd magic && git checkout "$MAGIC_TAG" >>"$LOG" 2>&1) || true
fi

# ---- 3) Configure ----
cd magic
NPROC="$(
  command -v sysctl >/dev/null && sysctl -n hw.ncpu 2>/dev/null ||
  command -v getconf >/dev/null && getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
)"

CONFIG_FLAGS=(
  "--prefix=$OPT_DIR"
  "--with-x"
  "--x-includes=$X11_PREFIX/include"
  "--x-libraries=$X11_PREFIX/lib"
  "--with-tcl=$TCL_PREFIX/lib"
  "--with-tk=$TCL_PREFIX/lib"
  "--with-cairo=$CAIRO_PREFIX/include"
  "--enable-cairo-offscreen"
)

info "Running ./configure …"
echo "./configure ${CONFIG_FLAGS[*]}" >>"$LOG"
if ! ./configure "${CONFIG_FLAGS[@]}" >>"$LOG" 2>&1; then
  err "Configure failed. See $LOG"
  exit 1
fi
ok "Configure OK."

# ---- 4) Build & Install ----
info "Building (make -j$NPROC)…"
if ! make -j"$NPROC" >>"$LOG" 2>&1; then
  err "Build failed. See $LOG"
  exit 1
fi
ok "Build OK."

info "Installing to $OPT_DIR …"
if ! make install >>"$LOG" 2>&1; then
  err "Install failed. See $LOG"
  exit 1
fi
ok "Installed."

# ---- 5) Wrapper and activate ----
WRAP="$BIN_DIR/magic"
cat >"$WRAP" <<EOF
#!/usr/bin/env bash
# exec the just-built magic
exec "$OPT_DIR/bin/magic" "\$@"
EOF
chmod +x "$WRAP"
ok "Wrapper: $WRAP"

cat >"$ACTIVATE" <<'EOF'
# ~/.eda/sky130/activate
export PATH="$HOME/.eda/sky130/bin:$PATH"
# Let XQuartz manage DISPLAY; uncomment only if you need to force it:
# export DISPLAY=:0
EOF
ok "Activate: $ACTIVATE"

# ---- 6) Headless sanity ----
info "Headless sanity check…"
SMOKE="$(mktemp /tmp/magic_smoke.XXXXXX.tcl)"
cat >"$SMOKE" <<'EOF'
puts "tech=[tech name]"
quit -noprompt
EOF
if ! "$WRAP" -dnull -noconsole -rcfile /dev/null "$SMOKE" >>"$LOG" 2>&1; then
  warn "Headless check failed; see $LOG"
else
  ok "Headless OK (details in $LOG)."
fi
rm -f "$SMOKE"

# ---- 7) GUI quick smoke ----
info "Starting/refreshing XQuartz…"
open -ga XQuartz || true
sleep 1
command -v xhost >/dev/null 2>&1 && xhost +localhost >/dev/null 2>&1 || true

GUI_TCL="$(mktemp /tmp/magic_gui.XXXXXX.tcl)"
cat >"$GUI_TCL" <<'EOF'
# open a layout window and quit shortly after
after 600 { quit -noprompt }
EOF

drivers=(X11 XR OGL)
GUI_OK=0
for d in "${drivers[@]}"; do
  info "Trying GUI driver: -d $d …"
  if "$WRAP" -d "$d" -noconsole -rcfile /dev/null "$GUI_TCL" >>"$LOG" 2>&1; then
    ok "GUI launched with: $d"
    GUI_OK=1
    break
  else
    warn "$d failed; trying next…"
  fi
done
rm -f "$GUI_TCL"

if [[ $GUI_OK -eq 0 ]]; then
  warn "All GUI drivers failed to quick-open. See: $LOG"
  say "You can still try manually after activating env: magic -d X11  (or XR/OGL)"
fi

say
ok "Done. Next:"
say '  1) source "$HOME/.eda/sky130/activate"'
say '  2) run: magic -d X11   # or XR / OGL'
say "Build log: $LOG"
