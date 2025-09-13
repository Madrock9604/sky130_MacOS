#!/usr/bin/env bash
# sky130-mac.sh — one-command macOS bootstrap + launcher for Magic + SKY130A
# Usage (students):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/<username>/<repo>/main/sky130-mac.sh)"
# Later:
#   sky130            # launches Magic (installs missing bits automatically)
#   sky130 --uninstall  # removes everything this script installed

set -euo pipefail

MACPORTS_PREFIX="/opt/local"
PDK_ROOT="/opt/pdk"
LAUNCHER="/usr/local/bin/sky130"
WORKDIR="${HOME}/.eda-bootstrap"
DEMO_DIR="${HOME}/sky130-demo"

say() { printf "\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }
err() { printf "\033[1;31m%s\033[0m\n" "$*"; }

need_xcode() {
  if ! xcode-select -p >/dev/null 2>&1; then
    say "Installing Xcode Command Line Tools (accept dialog if it pops up)…"
    xcode-select --install || true
    err "Finish CLT install, then re-run the sky130 command."
    exit 1
  fi
}

ensure_path_now() {
  export PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:$PATH"
}

ensure_macports() {
  if command -v port >/dev/null 2>&1; then return; fi
  say "Installing MacPorts via official .pkg…"
  swver=$(sw_vers -productVersion | cut -d. -f1,2)
  # crude mapping for known pkg names (update if newer macOS comes out)
  case "$swver" in
    15.*) PKG="MacPorts-2.10.4-15-Sequoia.pkg" ;;
    14.*) PKG="MacPorts-2.10.4-14-Sonoma.pkg" ;;
    13.*) PKG="MacPorts-2.10.4-13-Ventura.pkg" ;;
    12.*) PKG="MacPorts-2.10.4-12-Monterey.pkg" ;;
    *)    PKG="MacPorts-2.10.4.tar.bz2" ;; # fallback (source build)
  esac
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  if [[ "$PKG" == *.pkg ]]; then
    curl -fsSL "https://distfiles.macports.org/MacPorts/$PKG" -o "$PKG"
    sudo installer -pkg "$PKG" -target /
  else
    # fallback build from source if pkg not mapped
    curl -fsSL "https://distfiles.macports.org/MacPorts/$PKG" -o "$PKG"
    tar -xjf "$PKG"
    cd MacPorts-*
    ./configure --prefix="$MACPORTS_PREFIX"
    make -j"$(sysctl -n hw.ncpu)"
    sudo make install
  fi
  ensure_path_now
  sudo port -v selfupdate
}

ensure_xquartz() {
  if [[ -d "/Applications/XQuartz.app" || -d "/Applications/Utilities/XQuartz.app" ]]; then return; fi
  warn "Installing XQuartz…"
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  if curl -fsSL "https://api.github.com/repos/XQuartz/XQuartz/releases/latest" -o xq.json; then
    PKG_URL=$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json)
  fi
  if [[ -z "${PKG_URL:-}" ]]; then
    err "Could not auto-detect XQuartz pkg. Install manually from https://www.xquartz.org/"
    exit 1
  fi
  curl -fsSL "$PKG_URL" -o XQuartz.pkg
  sudo installer -pkg XQuartz.pkg -target /
}

ensure_tools() {
  say "Installing Magic/Netgen/NGSpice via MacPorts…"
  sudo port -N install git pkgconfig tcl tk magic netgen ngspice
}

ensure_pdk() {
  if [[ -d "$PDK_ROOT/sky130A" ]]; then return; fi
  say "Installing SKY130A PDK (open_pdks)…"
  sudo mkdir -p "$PDK_ROOT"; sudo chown "$(id -u)":"$(id -g)" "$PDK_ROOT"
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  if [[ -d open_pdks ]]; then cd open_pdks; git pull --rebase; else git clone https://github.com/RTimothyEdwards/open_pdks.git; cd open_pdks; fi
  ./configure --prefix="$PDK_ROOT" --enable-sky130-pdk --with-sky130-local-path="$PDK_ROOT" --enable-sram-sky130
  make -j"$(sysctl -n hw.ncpu)"
  sudo make install
}

ensure_demo() {
  mkdir -p "$DEMO_DIR"
  cat > "$DEMO_DIR/inverter_tt.spice" <<'EOF'
.option nomod
.option scale=1e-6
.lib $PDK_ROOT/sky130A/libs.tech/ngspice/sky130.lib.spice tt
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
}

install_launcher() {
  if [[ -x "$LAUNCHER" ]]; then return; fi
  say "Installing launcher: $LAUNCHER"
  cat <<'EOF' | sudo tee "$LAUNCHER" >/dev/null
#!/usr/bin/env bash
set -euo pipefail
PDK_ROOT_DEFAULT="/opt/pdk"
export PDK_ROOT="${PDK_ROOT:-$PDK_ROOT_DEFAULT}"
export PDK="${PDK:-sky130A}"
if ! pgrep -f XQuartz >/dev/null 2>&1; then open -a XQuartz || true; sleep 1; fi
exec magic -T "$PDK" "$@"
EOF
  sudo chmod +x "$LAUNCHER"
}

uninstall_all() {
  say "Uninstalling SKY130 stack…"
  sudo rm -f "$LAUNCHER"
  rm -rf "$DEMO_DIR"
  sudo rm -rf "$PDK_ROOT"
  if command -v port >/dev/null 2>&1; then
    sudo port -fp uninstall magic netgen ngspice || true
  fi
  say "✅ Uninstall complete."
  exit 0
}

main() {
  if [[ "${1:-}" == "--uninstall" ]]; then uninstall_all; fi
  need_xcode
  ensure_macports
  ensure_path_now
  ensure_xquartz
  ensure_tools
  ensure_pdk
  ensure_demo
  install_launcher
  say "Launching Magic…"
  "$LAUNCHER" || true
}

main "$@"
