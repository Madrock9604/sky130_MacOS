#!/usr/bin/env bash
# Build & install Magic (Tk 8.6 / Aqua + Cairo; NO OpenGL) into ~/.eda/sky130_dev
set -euo pipefail

# --- locations
EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
PREFIX_BIN="$EDA_PREFIX/bin"
PREFIX_LIB="$EDA_PREFIX/lib"
LOGDIR="${LOGDIR:-$HOME/sky130-diag}"
LOG="$LOGDIR/magic_install.log"
SRC_DIR="$HOME/.eda/src"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"

mkdir -p "$LOGDIR" "$PREFIX_BIN" "$SRC_DIR"
exec > >(tee -a "$LOG") 2>&1

die(){ echo "❌ $*" >&2; exit 1; }
ok(){ echo "✅ $*"; }

echo "Magic installer (Tk 8.6 / Aqua, Cairo, no OpenGL)"

# 0) Load brew into THIS shell and basic deps
if ! command -v brew >/dev/null 2>&1; then
  # if prereqs added shellenv to zprofile/zshrc, source it
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
fi
command -v brew >/dev/null || die "Homebrew not found. Run 00_prereqs_mac.sh first."
ok "Homebrew ready: $(command -v brew)"

# 1) Ensure Cairo present (quiet if already installed)
brew list --versions cairo >/dev/null 2>&1 || brew install cairo

# 2) Locate Tk 8.6 from prereqs and verify wish8.6
TK86_PREFIX="$(brew --prefix tcl-tk@8 2>/dev/null || true)"
[ -n "$TK86_PREFIX" ] && [ -x "$TK86_PREFIX/bin/wish8.6" ] || die "Tcl/Tk 8.6 not usable. Re-run 00_prereqs_mac.sh"
TK_VER="$("$TK86_PREFIX/bin/wish8.6" <<< 'puts [info patchlevel]; exit' 2>/dev/null || true)"
[[ "$TK_VER" == 8.6.* ]] || die "wish8.6 reports $TK_VER (need 8.6.x)."

# 3) Build flags so Magic finds keg-only Tk and Cairo
export PKG_CONFIG_PATH="$TK86_PREFIX/lib/pkgconfig:$(brew --prefix cairo)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I$TK86_PREFIX/include -I$(brew --prefix cairo)/include ${CPPFLAGS:-}"
export LDFLAGS="-L$TK86_PREFIX/lib -L$(brew --prefix cairo)/lib ${LDFLAGS:-}"
export WISH="${WISH:-$TK86_PREFIX/bin/wish8.6}"

# 4) Get magic source (shallow clone/update)
if [ -d "$SRC_DIR/magic/.git" ]; then
  echo "[INFO] Updating existing magic repo…"
  git -C "$SRC_DIR/magic" fetch --tags --depth 1 origin || true
  git -C "$SRC_DIR/magic" reset --hard origin/master
else
  echo "[INFO] Cloning magic…"
  git clone --depth 1 "$MAGIC_REPO" "$SRC_DIR/magic"
fi
cd "$SRC_DIR/magic"

# 5) Configure: force NO OpenGL; prefer Cairo; NO X11 (we’ll use Aqua via Tk)
#    The ac_cv_* vars tell autoconf “pretend GL headers/libs do not exist”.
export ac_cv_header_GL_gl_h=no
export ac_cv_header_OpenGL_gl_h=no
export ac_cv_lib_GL_glFlush=no
export ac_cv_lib_GL_glXCreateContext=no
export ac_cv_lib_GL_glBegin=no
export ac_cv_func_glXCreateContext=no

echo "[INFO] ./configure …"
./configure \
  --prefix="$EDA_PREFIX" \
  --with-tcl="$TK86_PREFIX/lib" --with-tk="$TK86_PREFIX/lib" \
  --with-tclincl="$TK86_PREFIX/include" --with-tkinc="$TK86_PREFIX/include" \
  --with-opengl=no --with-cairo=yes --with-x=no || die "configure failed."

# 6) Safety belt: if any W3D*/TOGL* objects crept into Makefiles, strip them.
if grep -R -E 'W3D|TOGL' graphics Makefile* >/dev/null 2>&1; then
  echo "[INFO] Patching Makefiles to remove 3D/OpenGL objects…"
  sed -E -i '' 's/[[:space:]]W3D[^[:space:]]*\.o//g' graphics/Makefile || true
  sed -E -i '' 's/[[:space:]]grTOGL[^[:space:]]*\.o//g' graphics/Makefile || true
  sed -E -i '' 's/[[:space:]]TOGL[^[:space:]]*\.o//g' graphics/Makefile || true
fi

# 7) Build & install
echo "[INFO] Building…"
make -j"$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" || die "make failed."
echo "[INFO] Installing…"
make install || die "make install failed."

# 8) Wrapper to ensure this Magic takes precedence
mkdir -p "$PREFIX_BIN"
cat > "$PREFIX_BIN/magic" <<'EOF'
#!/usr/bin/env bash
# Magic wrapper (repo build, Tk 8.6/Aqua + Cairo, no OpenGL)
PREFIX="$HOME/.eda/sky130_dev"
exec "$PREFIX/bin/magic" "$@"
EOF
chmod +x "$PREFIX_BIN/magic"

# 9) Headless smoke test (no -eval). Prints versions and exits.
SMOKE="$LOGDIR/magic-smoke.tcl"
cat > "$SMOKE" <<'EOF'
puts "Tcl: [info patchlevel]"
if {[catch {package require Tk}]} { puts "Tk: (not loaded)"; } else { puts "Tk: [tk patchlevel]" }
puts "Magic: [magic::version]"
quit -noprompt
EOF

echo "[INFO] Smoke test…"
"$PREFIX_BIN/magic" -d null -noconsole -rcfile /dev/null -T scmos "$SMOKE" || die "Smoke test failed."

ok "Magic built and installed at $PREFIX_BIN/magic"
echo "Try GUI (Aqua/Cairo):  magic -d XR -T scmos -rcfile /dev/null -wrapper"
