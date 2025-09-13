#!/usr/bin/env bash
# sky130-mac.sh — one-command macOS bootstrap + launcher for Magic + SKY130A
# Usage (students):
#   /bin/bash -c "$(curl -fsSL https://.../sky130-mac.sh)"
# Later:
#   sky130            # launches Magic (installs missing bits automatically)
#   sky130 --uninstall  # removes everything this script installed

set -euo pipefail

# --- Config (edit if desired) ---
MACPORTS_PREFIX="/opt/local"
PDK_ROOT="/opt/pdk"
LAUNCHER="/usr/local/bin/sky130"
WORKDIR="${HOME}/.eda-bootstrap"
DEMO_DIR="${HOME}/sky130-demo"
# -------------------------------

say() { printf "\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }
err() { printf "\033[1;31m%s\033[0m\n" "$*"; }

need_xcode() {
  if ! xcode-select -p >/dev/null 2>&1; then
    say "Installing Xcode Command Line Tools… (Apple dialog may appear)"
    xcode-select --install || true
    err "Finish the Command Line Tools install, then run this command again."
    exit 1
  fi
}

ensure_path_now() {
  export PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:$PATH"
}

ensure_macports() {
  if command -v port >/dev/null 2>&1; then return; fi
  say "Installing MacPorts (from source)…"
  mkdir -p "$WORKDIR"; pushd "$WORKDIR" >/dev/null
  # Use a stable tarball to avoid API rate limits
  MP_VER="2.10.4"
  MP_TGZ="MacPorts-${MP_VER}.tar.bz2"
  curl -fsSL "https://distfiles.macports.org/MacPorts/${MP_TGZ}" -o "$MP_TGZ"
  tar -xjf "$MP_TGZ"
  cd "MacPorts-${MP_VER}"
  ./configure --prefix="$MACPORTS_PREFIX"
  make -j"$(sysctl -n hw.ncpu)"
  sudo make install
  popd >/dev/null
  ensure_path_now
  # Persist PATH for new shells (best-effort)
  RC="${ZDOTDIR:-$HOME}/.zshrc"
  [[ -f "$RC" ]] || RC="$HOME/.bash_profile"
  [[ -f "$RC" ]] || RC="$HOME/.profile"
  if ! grep -q "$MACPORTS_PREFIX/bin" "$RC" 2>/dev/null; then
    say "Updating PATH in $RC"
    {
      echo ''
      echo '# Added by sky130-mac.sh'
      echo "export PATH=\"$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:\$PATH\""
    } >> "$RC"
  fi
  sudo "$MACPORTS_PREFIX/bin/port" -v selfupdate
}

ensure_xquartz() {
  if [[ -d "/Applications/XQuartz.app" || -d "/Applications/Utilities/XQuartz.app" ]]; then return; fi
  warn "XQuartz not found. Installing…"
  mkdir -p "$WORKDIR"; pushd "$WORKDIR" >/dev/null
  # Get latest pkg url via GitHub API; fall back to site if needed
  if curl -fsSL "https://api.github.com/repos/XQuartz/XQuartz/releases/latest" -o xq.json 2>/dev/null; then
    PKG_URL=$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json)
  fi
  if [[ -z "${PKG_URL:-}" ]]; then
    err "Could not auto-detect XQuartz pkg. Install manually from https://www.xquartz.org/ then re-run 'sky130'."
    exit 1
  fi
  curl -fsSL "$PKG_URL" -o XQuartz.pkg
  sudo installer -pkg XQuartz.pkg -target /
  popd >/dev/null
}

ensure_tools() {
  say "Installing Magic/Netgen/NGSpice via MacPorts…"
  sudo port -N install git pkgconfig tcl tk magic netgen ngspice
}

ensure_pdk() {
  if [[ -d "$PDK_ROOT/sky130A" ]]; then return; fi
  say "Installing SKY130A PDK via open_pdks…"
  sudo mkdir -p "$PDK_ROOT"; sudo chown "$(id -u)":"$(id -g)" "$PDK_ROOT"
  mkdir -p "$WORKDIR"; pushd "$WORKDIR" >/dev/null
  if [[ -d open_pdks ]]; then
    cd open_pdks; git pull --rebase
  else
    git clone https://github.com/RTimothyEdwards/open_pdks.git
    cd open_pdks
  fi
  ./configure --prefix="$PDK_ROOT" --enable-sky130-pdk --with-sky130-local-path="$PDK_ROOT" --enable-sram-sky130
  make -j"$(sysctl -n hw.ncpu)"
  sudo make install
  popd >/dev/null
  [[ -d "$PDK_ROOT/sky130A" ]] || { err "PDK install failed."; exit 1; }
}

ensure_demo() {
  [[ -d "$DEMO_DIR" ]] || mkdir -p "$DEMO_DIR"
  if [[ ! -f "$DEMO_DIR/inverter_tt.spice" ]]; then
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
  fi
  if [[ ! -f "$DEMO_DIR/magic_sky130_smoke.tcl" ]]; then
    cat > "$DEMO_DIR/magic_sky130_smoke.tcl" <<'EOF'
tech load sky130A
puts "Magic tech: [tech name]"
puts "Cells: [llength [cellname list]]"
quit -noprompt
EOF
  fi
}

install_launcher() {
  if [[ -x "$LAUNCHER" ]]; then return; fi
  say "Installing launcher: $LAUNCHER"
  TMP="$(mktemp)"
  cat > "$TMP" <<'EOF'
#!/usr/bin/env bash
# sky130 — launch Magic with SKY130A; auto-fix common env/GUI issues
set -euo pipefail
PDK_ROOT_DEFAULT="/opt/pdk"
export PDK_ROOT="${PDK_ROOT:-$PDK_ROOT_DEFAULT}"
export PDK="${PDK:-sky130A}"

# Start XQuartz if not running
if ! pgrep -f XQuartz >/dev/null 2>&1; then
  open -a XQuartz || true
  sleep 1
fi

# Launch Magic; pass through args to support -noconsole, etc.
exec magic -T "$PDK" "$@"
EOF
  sudo mkdir -p "$(dirname "$LAUNCHER")"
  sudo mv "$TMP" "$LAUNCHER"
  sudo chmod +x "$LAUNCHER"
}

launch_magic() {
  say "Launching Magic (SKY130A)…"
  export PDK_ROOT="$PDK_ROOT"
  "$LAUNCHER" || true
}

uninstall_all() {
  say "Uninstalling SKY130 stack…"
  # launcher
  [[ -f "$LAUNCHER" ]] && { say "• Removing launcher"; sudo rm -f "$LAUNCHER"; }
  # demo
  [[ -d "$DEMO_DIR" ]] && { say "• Removing demo"; rm -rf "$DEMO_DIR"; }
  # pdk
  [[ -d "$PDK_ROOT" ]] && { say "• Removing PDK"; sudo rm -rf "$PDK_ROOT"; }
  # ports/packages
  if command -v port >/dev/null 2>&1; then
    warn "• Removing MacPorts packages (magic/netgen/ngspice)…"
    sudo port -fp uninstall magic netgen ngspice || true
    warn "• (Optional) Remove ALL MacPorts & files? [y/N]"
    read -r ans
    if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
      sudo port -fp uninstall installed || true
      sudo rm -rf /opt/local /Applications/MacPorts /Library/LaunchDaemons/org.macports.* /Library/Tcl/macports1.0
      # Remove PATH lines we added (best effort)
      for rc in "${ZDOTDIR:-$HOME}"/.zshrc "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
        [[ -f "$rc" ]] || continue
        tmp="$(mktemp)"
        awk '!/Added by sky130-mac.sh/ && !/opt\/local\/bin/ && !/opt\/local\/sbin/' "$rc" > "$tmp" || true
        mv "$tmp" "$rc"
      done
    fi
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
  launch_magic
}

main "$@"

