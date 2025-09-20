#!/usr/bin/env bash
# Build & install Magic into ~/.eda/sky130_dev on macOS
# - Tcl/Tk 8.6 (Homebrew tcl-tk@8)
# - XQuartz (X11 headers/libs) present
# - Cairo enabled
# - OpenGL/3D disabled and stripped from Makefiles
# - No -Werror so warnings don't fail the build
set -euo pipefail

EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
SRC_DIR="${SRC_DIR:-$HOME/.eda/src}"
LOGDIR="${LOGDIR:-$HOME/sky130-diag}"
LOG="$LOGDIR/magic_install.log"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
X11_PREFIX="${X11_PREFIX:-/opt/X11}"

mkdir -p "$LOGDIR" "$EDA_PREFIX/bin" "$SRC_DIR"
exec > >(tee -a "$LOG") 2>&1

die(){ echo "❌ $*" >&2; exit 1; }
ok(){ echo "✅ $*"; }
info(){ echo "[INFO] $*"; }

echo "Magic installer (Tk 8.6, X11 headers via XQuartz, Cairo, NO OpenGL/3D)"

# 0) Ensure Homebrew in THIS shell
if ! command -v brew >/dev/null 2>&1; then
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
  [ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"
fi
command -v brew >/dev/null || die "Homebrew not found. Run scripts/00_prereqs_mac.sh first."

# 1) Ensure deps
brew list --versions git   >/dev/null 2>&1 || brew install git
brew list --versions cairo >/dev/null 2>&1 || brew install cairo
# XQuartz provides X11 headers/libs at /opt/X11
if ! [ -d "$X11_PREFIX/include/X11" ]; then
  info "Installing XQuartz (provides X11 headers/libs)…"
  brew install --cask xquartz
  # Give launchd a moment to place files
  sleep 2
fi
[ -d "$X11_PREFIX/include/X11" ] || die "X11 headers not found at $X11_PREFIX/include/X11"

# 2) Locate Tk 8.6 (from prereqs) and verify wish8.6
TK86_PREFIX="$(brew --prefix tcl-tk@8 2>/dev/null || true)"
[ -n "$TK86_PREFIX" ] && [ -x "$TK86_PREFIX/bin/wish8.6" ] || die "Tcl/Tk 8.6 not usable. Re-run scripts/00_prereqs_mac.sh"
TK_VER="$("$TK86_PREFIX/bin/wish8.6" <<< 'puts [info patchlevel]; exit' 2>/dev/null || true)"
[[ "$TK_VER" == 8.6.* ]] || die "wish8.6 reports $TK_VER (need 8.6.x)."

# 3) Build flags (keg-only Tk + Cairo + X11 includes/libs) and force NO OpenGL/3D
BASE_INC="-I. -I.. -I../database"
export PKG_CONFIG_PATH="$TK86_PREFIX/lib/pkgconfig:$(brew --prefix cairo)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="$BASE_INC -I$TK86_PREFIX/include -I$(brew --prefix cairo)/include -I$X11_PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$TK86_PREFIX/lib -L$(brew --prefix cairo)/lib -L$X11_PREFIX/lib ${LDFLAGS:-}"
# Be tolerant of old C patterns; do not treat warnings as errors
export CFLAGS="${CFLAGS:-} -std=gnu11 -Wno-error -Wno-deprecated-non-prototype -Wno-deprecated-declarations"

# Tell configure/make that OpenGL does NOT exist
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

# 5) Configure: Tk 8.6, Cairo ON, X11 headers available, OpenGL OFF
info "./configure …"
./configure \
  --prefix="$EDA_PREFIX" \
  --with-tcl="$TK86_PREFIX/lib" \
  --with-tk="$TK86_PREFIX/lib" \
  --with-tclincl="$TK86_PREFIX/include" \
  --with-tkinc="$TK86_PREFIX/include" \
  --with-cairo=yes \
  --with-opengl=no \
  --with-x="$X11_PREFIX" || die "configure failed."

# 6) Patch Makefiles: strip 3D/OpenGL objs & -Werror; ensure parent includes
info "Patching Makefiles (remove 3D/OpenGL objects and -Werror; add parent includes)…"
find . -name 'Makefile' -o -name 'Makefile.in' | while read -r mf; do
  # Drop any 3D/OpenGL objs
  sed -E -i '' 's/[[:space:]]W3D[^[:space:]]*\.o//g' "$mf" || true
  sed -E -i '' 's/[[:space:]]TOGL[^[:space:]]*\.o//g' "$mf" || true
  sed -E -i '' 's/[[:space:]]grTOGL[^[:space:]]*\.o//g' "$mf" || true
  # Drop -Werror variants that turn warnings into build failures
  sed -E -i '' 's/[[:space:]]-Werror([=][^[:space:]]*)?//g' "$mf" || true
  # Make sure common flags get parent includes for subdir builds
  sed -E -i '' 's/^(CFLAGS[[:space:]]*=[[:space:]].*)$/\1 '"$BASE_INC"'/g' "$mf" || true
  sed -E -i '' 's/^(CPPFLAGS[[:space:]]*=[[:space:]].*)$/\1 '"$BASE_INC"'/g' "$mf" || true
  sed -E -i '' 's/^(CCOPTIONS[[:space:]]*=[[:space:]].*)$/\1 '"$BASE_INC"'/g' "$mf" || true
done

# Safety symlinks so subdirs can resolve "database/database.h" via CWD if needed
for d in cmwind bplane; do
  [ -d "$d" ] && ln -snf ../database "$d/database"
done

# 7) Build (serial while stabilizing) & install
info "Building (serial)…"
make -j1 || die "make failed."
info "Installing…"
make install || die "make install failed."

# 8) Headless smoke test
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
echo "Open GUI (X11/Cairo):  magic -d X11 -T scmos -rcfile /dev/null -wrapper"
