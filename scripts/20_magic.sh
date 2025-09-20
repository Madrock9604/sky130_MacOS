#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# scripts/20_magic.sh  —  Fresh installer for MAGIC on macOS
# Installs & builds MAGIC into ~/.eda/sky130_dev with:
#   • Tcl/Tk 8.6 (Homebrew tcl-tk@8)
#   • XQuartz/X11 headers & libs (via Homebrew cask)
#   • Cairo enabled
#   • OpenGL/3D fully disabled & stripped from Makefiles
#   • No -Werror, so warnings won't fail the build
#
# Logs:  ~/sky130-diag/magic_install.log
# After install, run GUI:  magic -d X11 -T scmos -rcfile /dev/null -wrapper
# -----------------------------------------------------------------------------
set -euo pipefail

# ---- locations / config
EDA_PREFIX="${EDA_PREFIX:-$HOME/.eda/sky130_dev}"
SRC_DIR="${SRC_DIR:-$HOME/.eda/src}"
LOGDIR="${LOGDIR:-$HOME/sky130-diag}"
LOG="$LOGDIR/magic_install.log"
MAGIC_REPO="${MAGIC_REPO:-https://github.com/RTimothyEdwards/magic.git}"
X11_PREFIX="${X11_PREFIX:-/opt/X11}"   # XQuartz install path on macOS

mkdir -p "$LOGDIR" "$EDA_PREFIX/bin" "$SRC_DIR"
exec > >(tee -a "$LOG") 2>&1

say(){ printf "[INFO] %s\n" "$*"; }
ok(){  printf "✅ %s\n" "$*"; }
die(){ printf "❌ %s\n" "$*\n" >&2; exit 1; }

echo "MAGIC fresh installer (Tk 8.6, X11 via XQuartz, Cairo, no OpenGL/3D)"

# ---- 0) Ensure Homebrew in THIS shell
if ! command -v brew >/dev/null 2>&1; then
  [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)" || true
  [ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"    || true
fi
command -v brew >/dev/null || die "Homebrew not found. Run scripts/00_prereqs_mac.sh first."

# ---- 1) Core deps (idempotent)
for pkg in git cairo pkg-config gawk make wget; do
  brew list --versions "$pkg" >/dev/null 2>&1 || brew install "$pkg"
done
ok "Common deps installed"

# ---- 2) Tk 8.6 (keg-only) — verify via wish8.6
brew list --versions tcl-tk@8 >/dev/null 2>&1 || brew install tcl-tk@8 || true
TK86_PREFIX="$(brew --prefix tcl-tk@8 2>/dev/null || true)"
[ -n "$TK86_PREFIX" ] && [ -x "$TK86_PREFIX/bin/wish8.6" ] || {
  say "Reinstalling tcl-tk@8 to ensure wish8.6…"
  brew reinstall tcl-tk@8 || true
  TK86_PREFIX="$(brew --prefix tcl-tk@8 2>/dev/null || true)"
}
TK_VER="$("$TK86_PREFIX/bin/wish8.6" <<< 'puts [info patchlevel]; exit' 2>/dev/null || true)"
[[ "$TK_VER" == 8.6.* ]] || die "wish8.6 not usable (version: $TK_VER)."

ok "Tk $TK_VER at $TK86_PREFIX"

# ---- 3) XQuartz (X11 headers/libs) — needed by Magic's Tk graphics code
if ! [ -d "$X11_PREFIX/include/X11" ]; then
  say "Installing XQuartz (X11 headers/libs)…"
  brew install --cask xquartz
  # give launchd a moment
  sleep 2
fi
[ -d "$X11_PREFIX/include/X11" ] || die "X11 headers not found at $X11_PREFIX/include/X11"

# ---- 4) Build flags: keg-only Tk, Cairo, X11, and tolerant C flags
BASE_INC="-I. -I.. -I../database"
export PKG_CONFIG_PATH="$TK86_PREFIX/lib/pkgconfig:$(brew --prefix cairo)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="$BASE_INC -I$TK86_PREFIX/include -I$(brew --prefix cairo)/include -I$X11_PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$TK86_PREFIX/lib -L$(brew --prefix cairo)/lib -L$X11_PREFIX/lib ${LDFLAGS:-}"
# Clang tolerance: avoid C23 proto breakage & don't fail on deprecations
export CFLAGS="${CFLAGS:-} -std=gnu11 -Wno-error -Wno-deprecated-non-prototype -Wno-deprecated-declarations"

# Force OpenGL off at configure-time (even if headers are present)
export ac_cv_header_GL_gl_h=no
export ac_cv_header_OpenGL_gl_h=no
export ac_cv_lib_GL_glFlush=no
export ac_cv_lib_GL_glXCreateContext=no
export ac_cv_lib_GL_glBegin=no
export ac_cv_func_glXCreateContext=no

# ---- 5) Fetch Magic source (shallow); clean
mkdir -p "$SRC_DIR"
if [ -d "$SRC_DIR/magic/.git" ]; then
  say "Updating magic source…"
  git -C "$SRC_DIR/magic" fetch --tags --depth 1 origin || true
  git -C "$SRC_DIR/magic" reset --hard origin/master
else
  say "Cloning magic…"
  git clone --depth 1 "$MAGIC_REPO" "$SRC_DIR/magic"
fi
cd "$SRC_DIR/magic"
make distclean >/dev/null 2>&1 || true

# ---- 6) Configure: Tk 8.6, Cairo ON, X11 headers, OpenGL OFF
say "./configure …"
./configure \
  --prefix="$EDA_PREFIX" \
  --with-tcl="$TK86_PREFIX/lib" \
  --with-tk="$TK86_PREFIX/lib" \
  --with-tclincl="$TK86_PREFIX/include" \
  --with-tkinc="$TK86_PREFIX/include" \
  --with-cairo=yes \
  --with-opengl=no \
  --with-x="$X11_PREFIX" || die "configure failed."

# ---- 7) Patch Makefiles: remove 3D/TOGL objs, drop -Werror, ensure parent includes
say "Patching Makefiles (strip OpenGL/3D, remove -Werror, add parent includes)…"
find . -name 'Makefile' -o -name 'Makefile.in' | while read -r mf; do
  # strip any 3D/OpenGL objects that may sneak in
  sed -E -i '' 's/[[:space:]]W3D[^[:space:]]*\.o//g' "$mf" || true
  sed -E -i '' 's/[[:space:]]TOGL[^[:space:]]*\.o//g' "$mf" || true
  sed -E -i '' 's/[[:space:]]grTOGL[^[:space:]]*\.o//g' "$mf" || true
  # remove -Werror so warnings don't fail the build
  sed -E -i '' 's/[[:space:]]-Werror([=][^[:space:]]*)?//g' "$mf" || true
  # ensure subdirs see parent headers (database/, etc.)
  sed -E -i '' 's/^(CFLAGS[[:space:]]*=[[:space:]].*)$/\1 '"$BASE_INC"'/g' "$mf" || true
  sed -E -i '' 's/^(CPPFLAGS[[:space:]]*=[[:space:]].*)$/\1 '"$BASE_INC"'/g' "$mf" || true
  sed -E -i '' 's/^(CCOPTIONS[[:space:]]*=[[:space:]].*)$/\1 '"$BASE_INC"'/g' "$mf" || true
done

# safety symlinks so subdirs can resolve "database/database.h" via CWD if needed
for d in cmwind bplane; do
  [ -d "$d" ] && ln -snf ../database "$d/database"
done

# ---- 8) Build serially (more deterministic on macOS) & install
say "Building (serial)…"
make -j1 || die "make failed."
say "Installing…"
make install || die "make install failed."

# ---- 9) Smoke test (headless)
SMOKE="$LOGDIR/magic-smoke.tcl"
cat > "$SMOKE" <<'EOF'
puts "Tcl: [info patchlevel]"
if {[catch {package require Tk}]} { puts "Tk: (not loaded)"; } else { puts "Tk: [tk patchlevel]" }
puts "Magic: [magic::version]"
quit -noprompt
EOF
say "Smoke test…"
"$EDA_PREFIX/bin/magic" -d null -noconsole -rcfile /dev/null -T scmos "$SMOKE" || die "Smoke test failed."

ok "MAGIC installed at $EDA_PREFIX/bin/magic"
echo ""
echo "Run GUI (X11/Cairo):"
echo "  magic -d X11 -T scmos -rcfile /dev/null -wrapper"
echo ""
echo "Log: $LOG"
