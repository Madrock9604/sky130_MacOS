# macOS Sky130 Environment Installer

Spin up a full **SKY130** open-source IC design environment on macOS (Apple Silicon & Intel) with one command. This repo automates installing core tools (Magic, Xschem, ngspice, Netgen, KLayout) and the **open_pdks** SKY130A PDK, sets environment variables, and verifies the setup.

> **What is SKY130?** SkyWater’s open 130‑nm CMOS process and PDK ("sky130A") used for mixed‑signal digital/analog ASIC design.

---

## Quick start

> Replace `<USER>/<REPO>` with your GitHub path if you’re using the one‑liner.

```bash
# 1) Install Apple Command Line Tools (if you haven’t already)
xcode-select --install || true

# 2) Run the installer (Homebrew-based)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/scripts/install-mac.sh)"
```

When it finishes, **open a new terminal** (or `source ~/.zprofile`) and run the smoke tests below.

---

## What gets installed

- **System deps**: Xcode CLT, **Homebrew**, **XQuartz** (X11 server)
- **Build deps**: git, cmake, autoconf/automake/libtool, pkg-config, readline, tcl-tk
- **EDA tools**:
  - **Magic** (layout) — built with X11 support
  - **Xschem** (schematic capture)
  - **ngspice** (SPICE simulator)
  - **Netgen** (LVS)
  - **KLayout** (viewer/DRC; binary install via brew cask)
- **PDK**: **open_pdks** with **sky130A** installed under `$PDK_ROOT/sky130A` (by default `PDK_ROOT="$PDK_PREFIX/share/pdk"` with `PDK_PREFIX="$HOME/eda/pdks"`)
- **Shell config**: exports for `PDK_ROOT`, updated `PATH` so the tools are callable

> An optional **Conda** env (`eda-sky130`) can be created if you enable it in `scripts/install-mac.sh`. Default is system/Homebrew builds for best GUI stability.

---

## Requirements

- macOS 12 Monterey or newer (tested on 12 → 15).  
- Internet access & ~10–15 GB free disk space.

> Apple Silicon (M1–M4) is fully supported. Rosetta is **not** required.

---

## Repo layout

```
.
├── scripts/
│   ├── install-mac.sh          # main entrypoint (Homebrew + source builds)
│   ├── install-macports.sh     # optional alternative using MacPorts (off by default)
│   ├── postinstall.sh          # sets env vars, runs open_pdks, smoke tests
│   ├── uninstall.sh            # best-effort removal
│   └── helpers/*.sh            # small idempotent steps
├── test/
│   ├── inverter.mag            # tiny Magic cell for smoke test
│   ├── rcx_test.spice          # ngspice sanity netlist
│   └── xschem/inverter.sch     # minimal xschem schematic
├── docs/
│   └── TROUBLESHOOTING.md
└── README.md
```

---

$1```bash
# Where open_pdks is installed
export PDK_PREFIX="$HOME/eda/pdks"           # you can change this root prefix
export PDK_ROOT="$PDK_PREFIX/share/pdk"      # <— open_pdks installs sky130A here

# Convenience (some tools still read this)
export SKYWATER_PDK="$PDK_ROOT/sky130A"
export OPEN_PDKS_ROOT="$PDK_PREFIX"
export MAGTYPE=mag

# Homebrew Tcl/Tk on macOS (improves Magic/Xschem stability)
BREW_TCLTK_PREFIX="$(brew --prefix tcl-tk 2>/dev/null || true)"
if [ -n "$BREW_TCLTK_PREFIX" ]; then
  export LDFLAGS="-L$BREW_TCLTK_PREFIX/lib${LDFLAGS:+ $LDFLAGS}"
  export CPPFLAGS="-I$BREW_TCLTK_PREFIX/include${CPPFLAGS:+ $CPPFLAGS}"
  export PKG_CONFIG_PATH="$BREW_TCLTK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
```

Open a **new** terminal (or `source ~/.zprofile`) after install so these take effect.

---

## Smoke tests (verify your setup)

1) **Magic + SKY130 tech**
```bash
magic -T sky130A -noconsole -d XR &
# Magic GUI should open. In the console:  :tech load sky130A   then  :quit
```

2) **Xschem finds SKY130 symbols**
```bash
xschem &     # File → Open → test/xschem/inverter.sch → Simulate
```

3) **ngspice runs**
```bash
ngspice -v
ngspice test/rcx_test.spice
```

4) **KLayout**
```bash
klayout -v
```

5) **PDK presence**
```bash
[ -d "$PDK_ROOT/sky130A" ] && echo "sky130A present" || echo "PDK missing"
```

---

## Usage pointers

- **Project location**: place your designs under `~/eda/projects/<your-project>` and reference the tech `sky130A` in Magic.  
- **Xschem-SPICE link**: Use `Simulation → Netlist` and simulate in ngspice.  
- **LVS**: Run `netgen -batch lvs layout.spice schematic.spice sky130A_setup.tcl report.lvs`.

---

## Uninstall

Best-effort cleanup (tools & PDK; won’t remove Homebrew itself):
```bash
./scripts/uninstall.sh
```

---

## Common issues & fixes

### 1) Magic launches then crashes (Tk/Wish 8.6)
- Ensure **XQuartz** is installed and you’ve logged out/in once after first install.
- Prefer **Homebrew** `tcl-tk` over system Tk. The installer exports correct flags.
- If you have **MacPorts** Tk in `/opt/local`, ensure it’s not shadowing Homebrew’s; or use `install-macports.sh` *only*.

### 2) Black/empty X11 window
- Start XQuartz once from Applications, then quit and retry Magic.
- Reset DISPLAY: `export DISPLAY=:0` (XQuartz usually bridges this automatically).

### 3) `magic: cannot open display`
- Start XQuartz, then run: `defaults write org.xquartz.X11 enable_iglx -bool true` and restart XQuartz.

### 4) Xschem can’t find SKY130 symbols
- Verify `$PDK_ROOT/sky130A` exists. Re-run `scripts/postinstall.sh`.
- Check `~/.xschem/xschemrc` includes a `symbol_path` pointing to sky130 libraries (the installer writes this).

See more in **docs/TROUBLESHOOTING.md**.

---

## Advanced

- **MacPorts path**: If you prefer MacPorts, run `scripts/install-macports.sh`. It uses `/opt/local` prefixes and MacPorts Tcl/Tk, avoiding mixing with Homebrew.
- **Headless**: You can pass `--headless` to skip GUI tools. Useful for CI.
- **Offline/cache**: Put tarballs in `cache/` prior to install; the scripts will pick them up.

---

## Contributing

PRs welcome! Please run `scripts/lint.sh` before committing. For feature requests or macOS regressions, open an issue with your macOS version, chip (Intel/Apple Silicon), and the installer log (attach `install.log`).

---

## Acknowledgments

- **SkyWater Technology** & **Google** for the open SKY130 PDK
- **open_pdks**, **Magic**, **Xschem**, **ngspice**, **Netgen**, **KLayout** maintainers and contributors

---

## License

MIT (see `LICENSE`).

