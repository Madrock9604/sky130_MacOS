# macOS Sky130 Environment Installer
Spin up a full SKY130 open-source IC design environment on macOS (Apple Silicon & Intel) with one command. This repo automates installing core tools (Magic, Xschem, ngspice, Netgen, KLayout) and the open_pdks SKY130A PDK, sets environment variables, and verifies the setup.

What is SKY130? SkyWater’s open 130‑nm CMOS process and PDK ("sky130A") used for mixed‑signal digital/analog ASIC design.

# Quick start
## 1) Install Apple Command Line Tools (if you haven’t already)
xcode-select --install || true

## 2) Run the installer (Homebrew-based)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/scripts/install-mac.sh)"

# What gets installed

✅ System deps: Xcode CLT, Homebrew, XQuartz (X11 server)

✅ Build deps: git, cmake, autoconf/automake/libtool, pkg-config, readline, tcl-tk

## EDA tools:

✅ Magic (layout) — built with X11 support

❌ Xschem (schematic capture)

⚠️ ngspice (SPICE simulator)

⚠️ Netgen (LVS)

✅ KLayout (viewer/DRC; binary install via brew cask)

✅ PDK: open_pdks with sky130A installed to $PDK_ROOT/sky130A

✅ Shell config: exports for PDK_ROOT, updated PATH so the tools are callable

# Requirements
macOS 12 Monterey or newer (tested on 12 → 15).

Internet access & ~10–15 GB free disk space.

Apple Silicon (M1–M4) is fully supported. Rosetta is not required.

# Environment variables
The installer appends to your shell startup (e.g. ~/.zprofile or ~/.zshrc):

export PDK_ROOT="$HOME/eda/pdks"

export SKYWATER_PDK="$PDK_ROOT/sky130A"

export MAGTYPE=mag

export OPEN_PDKS_ROOT="$PDK_ROOT"

#Homebrew tcl-tk on Apple Silicon

export LDFLAGS="-L/opt/homebrew/opt/tcl-tk/lib"

export CPPFLAGS="-I/opt/homebrew/opt/tcl-tk/include"

export PKG_CONFIG_PATH="/opt/homebrew/opt/tcl-tk/lib/pkgconfig:$PKG_CONFIG_PATH"

# Usage pointers

Project location: place your designs under ~/eda/projects/<your-project> and reference the tech sky130A in Magic.

❌ Xschem-SPICE link: Use Simulation → Netlist and simulate in ngspice.

⚠️ LVS: Run netgen -batch lvs layout.spice schematic.spice sky130A_setup.tcl report.lvs.

# Common issues & fixes

## 1) Magic launches then crashes (Tk/Wish 8.6)

Ensure XQuartz is installed and you’ve logged out/in once after first install.

Prefer Homebrew tcl-tk over system Tk. The installer exports correct flags.

If you have MacPorts Tk in /opt/local, ensure it’s not shadowing Homebrew’s; or use install-macports.sh only.

## 2) Black/empty X11 window

Start XQuartz once from Applications, then quit and retry Magic.

Reset DISPLAY: export DISPLAY=:0 (XQuartz usually bridges this automatically).

## 3) magic: cannot open display

Start XQuartz, then run: defaults write org.xquartz.X11 enable_iglx -bool true and restart XQuartz.

## 4) Xschem can’t find SKY130 symbols

Verify $PDK_ROOT/sky130A exists. Re-run scripts/postinstall.sh.

Check ~/.xschem/xschemrc includes a symbol_path pointing to sky130 libraries (the installer writes this).

See more in docs/TROUBLESHOOTING.md.

# Acknowledgments

SkyWater Technology & Google for the open SKY130 PDK

open_pdks, Magic, Xschem, ngspice, Netgen, KLayout maintainers and contributors
