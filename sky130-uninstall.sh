#!/usr/bin/env bash
# sky130-uninstall.sh — reset Magic+NGSpice+Netgen+xschem+Sky130 on macOS
# Removes: launchers, PDK (sky130A/B), demo/configs, MacPorts packages we installed.
# Offers: optional full MacPorts removal, optional XQuartz removal.

set -euo pipefail

say()  { printf "\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }
err()  { printf "\033[1;31m%s\033[0m\n" "$*"; }

# 0) Stop running tools (ignore errors)
pkill -x magic  2>/dev/null || true
pkill -x xschem 2>/dev/null || true

# 1) Remove launchers, demo, configs, logs, helper scripts
say "Removing launchers, demo, configs, and logs…"
sudo rm -f /usr/local/bin/magic-sky130 /usr/local/bin/sky130 /usr/local/bin/xschem-sky130

rm -rf "$HOME/sky130-demo" \
       "$HOME/.config/sky130" \
       "$HOME/sky130-diag" \
       "$HOME/.eda-bootstrap" 2>/dev/null || true

# Remove ONLY the xschemrc we created; keep any other user xschem files
if [ -f "$HOME/.xschem/xschemrc" ]; then
  say "Removing ~/.xschem/xschemrc"
  rm -f "$HOME/.xschem/xschemrc"
  rmdir "$HOME/.xschem" 2>/dev/null || true
fi

# Tidy .spiceinit: remove lines we added if present
if [ -f "$HOME/.spiceinit" ]; then
  say "Cleaning ~/.spiceinit entries we added…"
  tmp="$(mktemp)"
  # Remove the exact lines we may have written
  awk '!/^set[[:space:]]+ngbehavior=hsa$/ && !/^set[[:space:]]+ng_nomodcheck$/' "$HOME/.spiceinit" > "$tmp" || true
  # If file becomes empty (or whitespace only), remove it; else replace
  if [ ! -s "$tmp" ] || ! grep -q '[^[:space:]]' "$tmp"; then
    rm -f "$HOME/.spiceinit"
  else
    mv "$tmp" "$HOME/.spiceinit"
  fi
fi

# 2) Remove Sky130 PDK files (both layouts; both A/B)
say "Removing SKY130 PDK directories… (sudo)"
for base in /opt/pdk /opt/pdk/share/pdk; do
  sudo rm -rf "$base/sky130A" "$base/sky130B" 2>/dev/null || true
done
# Prune empty dirs (best effort)
sudo rmdir /opt/pdk/share/pdk 2>/dev/null || true
sudo rmdir /opt/pdk/share     2>/dev/null || true
sudo rmdir /opt/pdk           2>/dev/null || true

# 3) Uninstall MacPorts packages we installed (skip if MacPorts missing)
if command -v port >/dev/null 2>&1; then
  say "Uninstalling MacPorts ports (magic, netgen, ngspice, xschem, xterm, tk)…"
  sudo port -fp uninstall magic  || true
  sudo port -fp uninstall netgen || true
  sudo port -fp uninstall ngspice || true
  sudo port -fp uninstall xschem || true
  sudo port -fp uninstall xterm  || true
  sudo port -fp uninstall tk     || true
else
  warn "MacPorts not found; skipping port uninstalls."
fi

# 4) Optional: remove ALL of MacPorts (use with care)
if command -v port >/dev/null 2>&1; then
  echo
  read -r -p "Remove MacPorts ENTIRELY (all ports & /opt/local)? [y/N]: " ans_mp
  if [[ "${ans_mp:-N}" =~ ^[Yy]$ ]]; then
    say "Removing ALL MacPorts ports and files… (sudo)"
    sudo port -fp uninstall installed || true
    sudo rm -rf /opt/local /Applications/MacPorts /Library/Tcl/macports1.0 \
                /Library/LaunchDaemons/org.macports.* 2>/dev/null || true
  else
    say "Keeping MacPorts base."
  fi
fi

# 5) Optional: remove XQuartz
if [[ -d /Applications/XQuartz.app || -d /Applications/Utilities/XQuartz.app || -d /opt/X11 ]]; then
  echo
  read -r -p "Remove XQuartz as well? [y/N]: " ans_xq
  if [[ "${ans_xq:-N}" =~ ^[Yy]$ ]]; then
    say "Removing XQuartz files… (sudo)"
    sudo rm -rf /opt/X11 2>/dev/null || true
    # Forget pkg receipt if present
    if pkgutil --pkgs | grep -iq xquartz; then
      sudo pkgutil --forget org.xquartz.X11 2>/dev/null || true
    fi
  else
    say "Keeping XQuartz."
  fi
fi

say "✅ Reset complete."

# Quick sanity messages for the user
echo
command -v magic-sky130 >/dev/null 2>&1 || echo "• magic-sky130 removed"
command -v xschem-sky130 >/dev/null 2>&1 || echo "• xschem-sky130 removed"
if [ ! -d /opt/pdk/sky130A ] && [ ! -d /opt/pdk/sky130B ] && \
   [ ! -d /opt/pdk/share/pdk/sky130A ] && [ ! -d /opt/pdk/share/pdk/sky130B ]; then
  echo "• Sky130 PDK removed"
fi
echo
echo "You can now re-run your installer one-liner when ready."
