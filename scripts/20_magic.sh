#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# scripts/20_magic.sh — Install Magic via MacPorts (stable Tk-X11 build) on macOS
# - Installs XQuartz (X11), MacPorts (if missing), then `port install magic`
# - Creates ~/.eda/sky130_dev/bin/magic wrapper
# - Smoke-tests headless; prints how to launch GUI
#
# Logs: ~/sky130-diag/magic_install.log
# -----------------------------------------------------------------------------
set -euo pipefail

EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
LOGDIR="${LOGDIR:-$HOME/sky130-diag}"
LOG="$LOGDIR/magic_install.log"
MP_PREFIX="/opt/local"
X11_PREFIX="/opt/X11"

mkdir -p "$LOGDIR" "$EDA_PREFIX/bin"
exec > >(tee -a "$LOG") 2>&1

info(){ echo "[INFO] $*"; }
ok(){   echo "✅ $*"; }
die(){  echo "❌ $*" >&2; exit 1; }

echo "Magic installer (MacPorts build: Tk-X11 + cairo)"

# 0) Ensure Homebrew in THIS shell (for XQuartz cask)
if ! command -v brew >/dev/null 2>&1; then
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)" || true
  [ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"    || true
fi
command -v brew >/dev/null || die "Homebrew not found. Please run scripts/00_prereqs_mac.sh first."

# 1) Install XQuartz (X11 server & headers; safe if already installed)
if ! [ -d "$X11_PREFIX/include/X11" ]; then
  info "Installing XQuartz (X11)…"
  brew install --cask xquartz
  sleep 2
fi
[ -d "$X11_PREFIX/include/X11" ] || die "XQuartz not found at $X11_PREFIX (install failed)."

# 2) Install MacPorts (pkg) if missing (Sequoia)
if ! command -v port >/dev/null 2>&1; then
  info "Installing MacPorts…"
  PKG_URL="https://github.com/macports/macports-base/releases/download/v2.11.5/MacPorts-2.11.5-15-Sequoia.pkg"
  PKG="/tmp/MacPorts-2.11.5-15-Sequoia.pkg"
  curl -fsSL "$PKG_URL" -o "$PKG"
  sudo /usr/sbin/installer -pkg "$PKG" -target /
  rm -f "$PKG"
fi
command -v port >/dev/null 2>&1 || die "MacPorts not on PATH after install."
export PATH="$MP_PREFIX/bin:$MP_PREFIX/sbin:$PATH"

# 3) Update ports tree and install magic (pulls tk-x11, cairo, Xorg libs)
info "Updating MacPorts…"
sudo port -N selfupdate
info "Installing magic (tk-x11 backend)…"
sudo port -N install magic

# 4) Wrapper in ~/.eda/sky130_dev/bin so users call the right Magic
WRAP="$EDA_PREFIX/bin/magic"
cat > "$WRAP" <<'EOF'
#!/usr/bin/env bash
exec /opt/local/bin/magic "$@"
EOF
chmod +x "$WRAP"
ok "Wrapper created: $WRAP"

# 5) Headless smoke test
SMOKE="$LOGDIR/magic-smoke.tcl"
cat > "$SMOKE" <<'EOF'
puts "Magic: [magic::version]"
puts "Tcl: [info patchlevel]"
if {[catch {package require Tk} msg]} { puts "Tk: (not loaded) $msg" } else { puts "Tk: [tk patchlevel]" }
quit -noprompt
EOF

info "Smoke test…"
"$WRAP" -d null -noconsole -rcfile /dev/null -T scmos "$SMOKE" || die "Smoke test failed."

ok "Magic installed and working."
echo
echo "Launch the GUI (X11):"
echo "  magic -d X11 -T scmos -rcfile /dev/null -wrapper"
echo
echo "If XQuartz didn’t auto-start the first time, run:"
echo "  open -a XQuartz && xhost +localhost"
echo
echo "Log: $LOG"
