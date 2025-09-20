#!/usr/bin/env bash
# Build & install Magic (Tk 8.6 / Aqua + Cairo; NO OpenGL/3D) into ~/.eda/sky130_dev
set -euo pipefail

EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
SRC_DIR="${SRC_DIR:-$HOME/.eda/src}"
LOGDIR="${LOGDIR:-$HOME/sky130-diag}"
LOG="$LOGDIR/magic_install.log"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"

mkdir -p "$LOGDIR" "$EDA_PREFIX/bin" "$SRC_DIR"
exec > >(tee -a "$LOG") 2>&1

die(){ echo "❌ $*" >&2; exit 1; }
ok(){ echo "✅ $*"; }
info(){ echo "[INFO] $*"; }

echo "Magic installer (Tk 8.6 / Aqua, Cairo, NO OpenGL/3D)"

# 0) Ensure Homebrew in THIS shell
if ! command -v brew >/dev/null 2>&1; then
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"
fi
command -v brew >/dev/null || die "Homebrew not found. Run scripts/00_prereqs_mac.sh first."

# 1) Ensure deps
brew list --versions git   >/dev/null 2>&1 || brew install git
brew list --versions cairo >/dev/null 2>&1 || brew install cairo

# 2) Locate Tk 8.6 (from prereqs) and verify wish8.6
TK86_PREFIX="$(brew --prefix tcl-tk@8 2>/dev/null || true)"
[ -n "$TK86_PREFIX" ] && [ -x "$TK86_PREFIX/bin/wish8.6" ] || die "Tcl/Tk 8.6 not usable. Re-run scripts/00_prereqs_mac.sh"
TK_VER="$("$TK86_PREFIX/bin/wish8.6" <<< 'puts [info patchlevel]; exit' 2>/dev/null || true)"
[[ "$TK_VER" == 8.6.* ]] || die "wish8.6 reports $TK_VER (need 8.6.x)."

# 3) Build flags (keg-only Tk + Cairo) and **force no OpenGL/3D**
#    Add missing relative include paths so subdir builds (e.g., cmwind/) see ../database headers.
EXTRA_INCLUDES="-I. -I.. -I../database -I../utils -I../tiles -I../hash -I../textio -I../commands -I../dbwind"
export PKG_CONFIG_PATH="$TK86_PREFIX/lib/pkgconfig:$(brew --prefix cairo)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="$EXTRA_INCLUDES -I$TK86_PREFIX/include -I$(brew --prefix cairo)/include ${CPPFLAGS:-}"
export LDFLAGS="-L$TK86_PREFIX/lib -L$(brew --prefix cairo)/lib ${LDFLAGS:-}"
# Make clang tolerant of older C patterns used by Magic sources.
export CFLAGS="${CFLAGS:-} -std=gnu11 -Wno-error -Wno-deprecated-non-prototype"

# Tell configure/make to pretend OpenGL does not exist.
export ac_cv_header_GL_gl_h=no
export ac_cv_header_OpenGL_gl_h=no
export ac_cv_lib_GL_glFlush=no
export ac_cv_lib_GL_glXCreateContext=no
export ac_cv_lib_GL_glBegin=no
export ac_cv_func_glXCreateContext=no

# 4) Get Magic source (shallow)
mkdir -p "$SRC_DIR"
if [ -d "$SRC_DIR/magic/.git" ]; then
  info "Updating existing magic repo…"
  git -C "$SRC_DIR/magic" fetch --tags --depth 1 origin || true
  git -C "$SRC_DIR/magic" reset --hard origin/master
else
  info "Cloning magic…"
  git clone --depth 1 "$MAGIC_REPO" "$SRC_DIR/magic"
fi
cd "$SRC_DIR/magic"
make distclean >/dev/null 2>&1 || true

# 5) Configure: Aqua/Tk 8.6 + Cairo; **no OpenGL, no X11**
info "./configure …"
./configure \
  --prefix="$EDA_PREFIX" \
  --with-tcl="$TK86_PREFIX/lib" --with-tk="$TK86_PREFIX/lib" \
  --with-tclincl="$TK86_PREFIX/include" --with-tkinc="$TK86_PREFIX/include" \
  --with-cairo=yes \
  --with-opengl=no \
  --with-x=no || die "configure failed."

# 6) Belt-and-suspenders: strip any W3D*/TOGL* objects from ALL Makefiles
info "Patching Makefiles to remove 3D/OpenGL objects…"
# macOS sed needs -i ''
find . -name 'Makefile' -o -name 'Makefile.in' | while read -r mf; do
  sed -E -i '' 's/[[:space:]]W3D[^[:space:]]*\.o//g' "$mf" || true
  sed -E -i '' 's/[[:space:]]TOGL[^[:space:]]*\.o//g' "$mf" || true
  sed -E -i '' 's/[[:space:]]grTOGL[^[:space:]]*\.o//g' "$mf" || true
done

# 7) Build (serial to avoid edge-ordering issues while stabilizing) & install
info "Building (serial)…"
make -j1 || die "make failed."
info "Installing…"
make install || die "make install failed."

# 8) Headless smoke test (no -eval)
SMOKE="$LOGDIR/magic-smoke.tcl"
cat > "$SMOKE" <<'EOF'
puts "Tcl: [info patchlevel]"
if {[catch {package require Tk}]} { puts "Tk: (not loaded)"; } else { puts "Tk: [tk patchlevel]" }
puts "Magic: [magic::version]"
quit -noprompt
EOF
info "Smoke test…"
"$EDA_PREFIX/bin/magic" -d null -noconsole -rcfile /dev/null -T scmos "$SMOKE" || die "Smoke test failed."

ok "Magic built and installed at $EDA_PREFIX/bin/magic"
echo "Open GUI (Aqua/Cairo):  magic -d XR -T scmos -rcfile /dev/null -wrapper"
