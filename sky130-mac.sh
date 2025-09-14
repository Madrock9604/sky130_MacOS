#!/usr/bin/env bash
# sky130-magic-only.sh — macOS one-liner for Magic (+XQuartz, Sky130 PDK, optional ngspice/netgen)
# Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/sky130-magic-only.sh)"
# Launchers after install:
#   magic-sky130           # Magic (GUI, X11, sized sanely)
#   magic-sky130 --safe    # Magic (headless)

set -euo pipefail

MACPORTS_PREFIX="/opt/local"
PDK_PREFIX="/opt/pdk"
WORKDIR="${HOME}/.eda-bootstrap"
DEMO_DIR="${HOME}/sky130-demo"
RC_DIR="${HOME}/.config/sky130"
MAGIC_LAUNCHER="/usr/local/bin/magic-sky130"

say()  { printf "\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }
err()  { printf "\033[1;31m%s\033[0m\n" "$*"; }
ensure_path_now(){ export PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:$PATH"; }

need_xcode() {
  if ! xcode-select -p >/dev/null 2>&1; then
    say "Installing Xcode Command Line Tools… (accept the Apple dialog)"
    xcode-select --install || true
    err "Finish installing Command Line Tools, then re-run this one-liner."
    exit 1
  fi
}

fix_macports_signing() {
  # Fix Sequoia Team-ID mismatch for MacPorts Tcl modules (tdbc et al.)
  say "Applying MacPorts signing/quarantine fix (sudo)…"
  sudo xattr -dr com.apple.quarantine /opt/local || true
  to_sign=()
  while IFS= read -r -d '' f; do to_sign+=("$f"); done < <(/usr/bin/find /opt/local/bin -maxdepth 1 -type f -name 'tclsh*' -print0)
  while IFS= read -r -d '' f; do to_sign+=("$f"); done < <(/usr/bin/find /opt/local/libexec/macports/lib -type f -name '*.dylib' -print0)
  while IFS= read -r -d '' f; do to_sign+=("$f"); done < <(/usr/bin/find /opt/local/lib -type f \( -name 'libtcl*.dylib' -o -name 'libtk*.dylib' \) -print0)
  for f in "${to_sign[@]}"; do
    sudo /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || true
  done
}

macports_ok() {
  /usr/bin/env -i PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$HOME" "$MACPORTS_PREFIX/bin/port" version >/dev/null 2>&1
}

reinstall_macports_source() {
  say "Reinstalling MacPorts from source (sudo)…"
  sudo rm -rf /opt/local /Applications/MacPorts /Library/Tcl/macports1.0 /Library/LaunchDaemons/org.macports.* 2>/dev/null || true
  local ver="2.10.4"
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  curl -fL "https://distfiles.macports.org/MacPorts/MacPorts-$ver.tar.bz2" -o "MacPorts-$ver.tar.bz2"
  tar xf "MacPorts-$ver.tar.bz2"
  cd "MacPorts-$ver"
  ./configure --prefix=/opt/local
  make -j"$(sysctl -n hw.ncpu)"
  sudo make install
  ensure_path_now
  sudo port -v selfupdate
}

ensure_macports() {
  if command -v port >/dev/null 2>&1; then
    if ! macports_ok; then
      fix_macports_signing
      macports_ok || { warn "MacPorts still failing; rebuilding from source…"; reinstall_macports_source; }
    fi
    return
  fi
  say "Installing MacPorts via official .pkg…"
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  swmaj="$(sw_vers -productVersion | awk -F. '{print $1}')"
  case "$swmaj" in
    15) PKG="MacPorts-2.10.4-15-Sequoia.pkg" ;;
    14) PKG="MacPorts-2.10.4-14-Sonoma.pkg"  ;;
    13) PKG="MacPorts-2.10.4-13-Ventura.pkg" ;;
    12) PKG="MacPorts-2.10.4-12-Monterey.pkg";;
    *)  err "Unsupported macOS ($(sw_vers -productVersion)). Install MacPorts manually, then re-run."; exit 1;;
  esac
  curl -fL --retry 3 "https://distfiles.macports.org/MacPorts/${PKG}" -o "$PKG"
  sudo installer -pkg "$PKG" -target /
  ensure_path_now
  if ! sudo port -v selfupdate; then
    fix_macports_signing
    sudo port -v selfupdate || { warn "Selfupdate still failing; rebuilding from source…"; reinstall_macports_source; }
  fi
}

ensure_xquartz() {
  if [[ -d "/Applications/XQuartz.app" || -d "/Applications/Utilities/XQuartz.app" ]]; then return; fi
  warn "XQuartz not found — fetching latest release…"
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  if curl -fsSL "https://api.github.com/repos/XQuartz/XQuartz/releases/latest" -o xq.json; then
    PKG_URL="$(awk -F\" '/"browser_download_url":/ && /\.pkg"/ {print $4; exit}' xq.json)"
  fi
  if [[ -z "${PKG_URL:-}" ]]; then
    err "Could not auto-detect XQuartz pkg. Install from https://www.xquartz.org/ and re-run."
    exit 1
  fi
  curl -fL "$PKG_URL" -o XQuartz.pkg
  sudo installer -pkg XQuartz.pkg -target /
}

ports_install() {
  say "Installing Magic via MacPorts… (forces Tk +x11, Magic +x11)"
  sudo port -N upgrade --enforce-variants tk +x11             || sudo port -N install tk +x11
  sudo port -N upgrade --enforce-variants magic +x11 -quartz  || sudo port -N install magic +x11
  # Optional but useful for class:
  sudo port -N install ngspice netgen || true
}

choose_pdk() {
  for base in "$PDK_PREFIX" "$PDK_PREFIX/share/pdk"; do
    for name in sky130A sky130B; do
      [[ -d "$base/$name" ]] && { printf "%s %s" "$base" "$name"; return 0; }
    done
  done
  return 1
}

install_pdk() {
  if choose_pdk >/dev/null; then return; fi
  say "Installing Sky130 PDK via open_pdks…"
  sudo mkdir -p "$PDK_PREFIX"; sudo chown "$(id -u)":"$(id -g)" "$PDK_PREFIX"
  mkdir -p "$WORKDIR"; cd "$WORKDIR"
  if [[ -d open_pdks/.git ]]; then
    cd open_pdks && git pull --rebase
  else
    git clone https://github.com/RTimothyEdwards/open_pdks.git
    cd open_pdks
  fi
  ./configure --prefix="$PDK_PREFIX" --enable-sky130-pdk --with-sky130-local-path="$PDK_PREFIX" --enable-sram-sky130
  make -j"$(sysctl -n hw.ncpu)"
  sudo make install
  if ! choose_pdk >/dev/null; then
    err "open_pdks finished but no sky130A/B found under $PDK_PREFIX. Check build output."
    exit 1
  fi
}

write_demo() {
  mkdir -p "$DEMO_DIR"
  cat > "$DEMO_DIR/inverter_tt.spice" <<'EOF'
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
  cat > "$DEMO_DIR/smoke.tcl" <<'EOF'
puts ">>> smoke: tech=[tech name]"
quit -noprompt
EOF
}

write_rc_wrapper() {
  mkdir -p "$RC_DIR"
  cat > "$RC_DIR/rc_wrapper.tcl" <<'EOF'
# Load PDK rc
if {![info exists env(PDK_ROOT)]} { set env(PDK_ROOT) "/opt/pdk" }
if {![info exists env(PDK)]}      { set env(PDK)      "sky130A" }
source "$env(PDK_ROOT)/$env(PDK)/libs.tech/magic/${env(PDK)}.magicrc"

# Sticky geometry so buttons are visible (1400x900 at +80+60)
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
}

install_magic_launcher() {
  say "Installing Magic launcher…"

  # Pick a writable target dir, prefer /usr/local/bin, else /opt/local/bin
  local target="/usr/local/bin/magic-sky130"
  if ! sudo install -d -m 755 /usr/local/bin 2>/dev/null; then
    warn "Could not create /usr/local/bin; falling back to /opt/local/bin."
    sudo install -d -m 755 /opt/local/bin
    target="/opt/local/bin/magic-sky130"
  fi

  # Write launcher
  sudo tee "$target" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
choose_pdk(){ for b in /opt/pdk /opt/pdk/share/pdk; do for n in sky130A sky130B; do [[ -d "$b/$n" ]]&&{ echo "$b" "$n"; return 0; }; done; done; return 1; }
read -r PDK_ROOT PDK < <(choose_pdk) || { echo "No SKY130 PDK found."; exit 1; }
export PDK_ROOT PDK
MAGIC_BIN="/opt/local/bin/magic"
RC_WRAPPER="$HOME/.config/sky130/rc_wrapper.tcl"
RC_PDK="$PDK_ROOT/$PDK/libs.tech/magic/${PDK}.magicrc"
RC="$RC_PDK"; [[ -f "$RC_WRAPPER" ]] && RC="$RC_WRAPPER"

# Ensure XQuartz is up and DISPLAY is set
pgrep -f XQuartz >/dev/null 2>&1 || { open -a XQuartz || true; sleep 3; }
LDISP="$(launchctl getenv DISPLAY || true)"
if [ -z "${LDISP:-}" ]; then
  for d in /private/tmp/com.apple.launchd.*; do
    [ -S "$d/org.xquartz:0" ] && LDISP="$d/org.xquartz:0" && break
  done
fi
export DISPLAY="${LDISP:-:0}"

CLEAN_ENV=(/usr/bin/env -i PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" SHELL=/bin/zsh TERM=xterm-256color LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DISPLAY="$DISPLAY" PDK_ROOT="$PDK_ROOT" PDK="$PDK")
echo ">>> magic-sky130 launcher: using RC=$RC"
if [[ "${1:-}" == "--safe" ]]; then
  exec "${CLEAN_ENV[@]}" "$MAGIC_BIN" -norcfile -dnull -noconsole -T "$PDK" -rcfile "$RC" "${@:2}"
fi
exec "${CLEAN_ENV[@]}" "$MAGIC_BIN" -norcfile -d X11 -T "$PDK" -rcfile "$RC" "$@"
EOF
  sudo chmod +x "$target"

  # If we fell back to /opt/local/bin but /usr/local/bin exists, add a convenience symlink
  if [[ "$target" = "/opt/local/bin/magic-sky130" && -d /usr/local/bin ]]; then
    sudo ln -sf "$target" /usr/local/bin/magic-sky130 || true
  fi

  say "Magic launcher installed at: $target"
}


write_spiceinit() {
  # Helpful NGSpice defaults (idempotent; harmless if ngspice not used)
  if [[ ! -f "$HOME/.spiceinit" ]] || ! grep -q 'ngbehavior' "$HOME/.spiceinit" 2>/dev/null; then
    printf "set ngbehavior=hsa\nset ng_nomodcheck\n" >> "$HOME/.spiceinit"
  fi
}

headless_check() {
  # Prove Magic loads the tech (prints the smoke line)
  read -r PDK_BASE PDK_NAME < <(choose_pdk)
  /usr/bin/env -i PATH="$MACPORTS_PREFIX/bin:$MACPORTS_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$HOME" DISPLAY=":0" PDK_ROOT="$PDK_BASE" PDK="$PDK_NAME" \
    /opt/local/bin/magic -norcfile -dnull -noconsole -T "$PDK_NAME" \
    -rcfile "$RC_DIR/rc_wrapper.tcl" "$DEMO_DIR/smoke.tcl" || true
}

main() {
  need_xcode
  ensure_macports
  ensure_path_now
  ensure_xquartz
  ports_install
  install_pdk
  write_demo
  write_rc_wrapper
  install_magic_launcher
  write_spiceinit
  say "Running quick headless check…"; headless_check
  say "✅ Install complete."
  echo
  echo "Launchers:"
  echo "  • magic-sky130           (Magic GUI)"
  echo "  • magic-sky130 --safe    (Magic headless)"
  echo
  echo "Demo:"
  echo "  • NGSpice demo: cd ~/sky130-demo && ngspice inverter_tt.spice"
  echo
  echo "Tips:"
  echo "  • If a Mac’s GUI is flaky, use 'magic-sky130 --safe'."
  echo "  • Window too big? The rc wrapper forces 1400x900 (+80,+60)."
}

main "$@"
