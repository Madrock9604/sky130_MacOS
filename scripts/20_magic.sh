#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# scripts/20_magic.sh — Install Magic via MacPorts (stable Tk-X11 build) on macOS
# - Installs XQuartz (X11), MacPorts (if missing), then `port install magic`
# - Auto-fixes python313 IDLE.app activation conflicts (common on macOS)
# - Creates ~/.eda/sky130_dev/bin/magic wrapper that exports TCL/TK library paths
# - Smoke-tests headless (no DISPLAY/Tk load), prints how to launch GUI
#
# Logs: ~/sky130-diag/magic_install.log
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Madrock9604/sky130_MacOS/refs/heads/main/scripts/20_magic.sh)"
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

# 0) Ensure Homebrew is visible in THIS shell (used for XQuartz cask)
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

# 2) Install MacPorts (pkg) if missing (macOS 15 / Sequoia)
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

# 3) Update ports tree
info "Updating MacPorts…"
sudo port -N selfupdate

# 4) Preempt Python 3.13 IDLE.app collision (common activation error)
if ! port -q installed python313 >/dev/null 2>&1; then
  sudo port -N install python313 || true
fi
if ! sudo port -f activate python313 >/dev/null 2>&1; then
  APP_DIR="/Applications/MacPorts/Python 3.13/IDLE.app"
  if [ -d "$APP_DIR" ]; then
    info "Moving stray $APP_DIR out of the way…"
    sudo mv "$APP_DIR" "${APP_DIR}.bak.$(date +%s)" || true
  fi
  sudo port -f activate python313 || true
fi

# 5) Install magic (pulls tk-x11, cairo, Xorg libs)
info "Installing magic (tk-x11 backend)…"
sudo port -N install magic

# 6) Wrapper in ~/.eda/sky130_dev/bin so repo users call the right Magic + Tk libs
WRAP="$EDA_PREFIX/bin/magic"
cat > "$WRAP" <<'EOF'
#!/usr/bin/env bash
# Ensure MacPorts Tcl/Tk script libraries are found (fixes "tk.tcl not found")
export TCL_LIBRARY=/opt/local/lib/tcl8.6
export TK_LIBRARY=/opt/local/lib/tk8.6
exec /opt/local/bin/magic "$@"
EOF
chmod +x "$WRAP"
ok "Wrapper created: $WRAP"

# 7) Headless smoke test (no Tk load -> no DISPLAY needed)
SMOKE="$LOGDIR/magic-smoke.tcl"
cat > "$SMOKE" <<'EOF'
puts "Magic: [magic::version]"
quit -noprompt
EOF

info "Smoke test…"
"$WRAP" -d null -noconsole -rcfile /dev/null -T scmos "$SMOKE" || die "Smoke test failed."

ok "Magic installed and working."

echo
echo "Launch the GUI (X11):"
echo "  open -a XQuartz"
echo "  /opt/X11/bin/xhost +localhost  >/dev/null 2>&1 || true"
echo "  export DISPLAY=:0"
echo "  magic -d X11 -T scmos -rcfile /dev/null -wrapper"
echo
echo "If :0 doesn't work on your Mac, run:"
echo '  export DISPLAY="$(ls -1d /private/tmp/com.apple.launchd.* 2>/dev/null | head -n1)/org.xquartz:0"'
echo
echo "Log: $LOG"
