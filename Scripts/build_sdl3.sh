#!/usr/bin/env bash
# build_sdl3.sh
#
# Builds SDL3 from upstream sources into a build-local prefix and stages
# libSDL3.so into the build/Libraries (SE1) and build/Libraries-SE2 (SE2)
# staging folders.
#
# SDL3 serves two purposes here:
#
#   1. Build time: DXVK Native's window-system integration compiles against
#      SDL3 headers. DXVK takes it as
#
#          lib_sdl3.partial_dependency(compile_args: true, includes: true)
#
#      i.e. headers and compile flags only, so the produced libdxvk_*.so have
#      no NEEDED entry for libSDL3 and dlopen "libSDL3.so.0" at runtime.
#
#   2. Run time: that dlopen has to find an SDL3. Leaving it to the host was
#      the previous arrangement and it is not dependable — SDL3 is new enough
#      that plenty of otherwise current distributions ship no libSDL3 at all,
#      and the ones that do ship whatever version they happened to freeze.
#      Shipping the same pinned build the DXVK binaries were compiled against
#      removes that variable, exactly like the bundled OpenAL removes it for
#      audio.
#
# Why build it instead of using the host's SDL3: Ubuntu 24.04 — the pinned CI
# runner image — has no libsdl3-dev package at all, and a developer machine may
# have any SDL3 version or none. Building one pinned version here means CI and
# local builds compile DXVK against identical headers AND ship that exact
# library.
#
# Because it is now a shipped artefact, the video backends matter: this build
# requires X11 and Wayland (see the assertion after the install step). Both are
# dlopened by SDL at runtime rather than linked, so the shipped library still
# depends on nothing but glibc — but their development headers must be present
# at build time or SDL silently produces a library that cannot open a window.
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── Libraries/          staging dir all SE1 dep scripts populate
#   ├── Libraries-SE2/      staging dir for the SE2 archive
#   ├── SDL/                shallow clone of libsdl-org/SDL at the pinned tag
#   ├── sdl3-prefix/        install prefix (headers + lib + pkgconfig)
#   └── sdl3.stamp          last-built tag (cache key)
#
# Usage:
#   ./build_sdl3.sh           Build (or no-op if cached) and stage.
#   ./build_sdl3.sh --clean   Wipe build dirs and rebuild from scratch.
#   ./build_sdl3.sh --print-stamp
#                             Print this build's cache stamp and exit without
#                             touching the network. The value is the content
#                             key CI caches the staged libraries under; see
#                             docs/building.md.
#
# On success the prefix is at $SDL3_PREFIX and its pkgconfig dir is
# $SDL3_PREFIX/lib/pkgconfig (build_dxvk.sh prepends that to PKG_CONFIG_PATH).
#
# Env-var overrides (defaults shown):
#   SDL3_VERSION      = 3.4.12   (upstream tag is release-$SDL3_VERSION)
#   SDL3_REPO         = https://github.com/libsdl-org/SDL.git
#   BUILD_DIR         = <repo>/build
#   SDL3_PREFIX       = $BUILD_DIR/sdl3-prefix
#   LIBRARIES_DIR     = $BUILD_DIR/Libraries
#   LIBRARIES_SE2_DIR = $BUILD_DIR/Libraries-SE2
#   JOBS              = $(nproc)
#
# Requirements: git, cmake, ninja (or make), gcc, g++, pkg-config, patchelf,
# readelf, plus the X11 and Wayland development packages (see docs/building.md).

set -euo pipefail

SDL3_VERSION="${SDL3_VERSION:-3.4.12}"
SDL3_REPO="${SDL3_REPO:-https://github.com/libsdl-org/SDL.git}"
SDL3_TAG="release-$SDL3_VERSION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"
SDL3_PREFIX="${SDL3_PREFIX:-$BUILD_DIR/sdl3-prefix}"
LIBRARIES_DIR="${LIBRARIES_DIR:-$BUILD_DIR/Libraries}"
LIBRARIES_SE2_DIR="${LIBRARIES_SE2_DIR:-$BUILD_DIR/Libraries-SE2}"
JOBS="${JOBS:-$(nproc)}"

SDL3_SRC_DIR="$BUILD_DIR/SDL"
SDL3_BUILD_DIR="$SDL3_SRC_DIR/_build"
STAMP_FILE="$BUILD_DIR/sdl3.stamp"

# The SONAME upstream produces. Asserted after the build: DXVK dlopens this
# exact name, and the shipped file is named libSDL3.so, so the two only meet
# because the consumer preloads the file and the SONAME then satisfies the
# dlopen. A major-version bump would break that silently.
EXPECTED_SONAME="libSDL3.so.0"

# Bumped whenever the cmake options below change in a way that alters the
# produced library. It is part of the stamp so an existing build/ tree from
# before the change is rebuilt rather than re-staged: the tag alone would
# still match and the old, differently-configured library would ship.
CONFIG_REV="2"
STAMP_CONTENT="$SDL3_TAG config$CONFIG_REV"

CLEAN=0
PRINT_STAMP=0
for arg in "$@"; do
    case "$arg" in
        --clean)       CLEAN=1 ;;
        --print-stamp) PRINT_STAMP=1 ;;
        -h|--help) sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$PRINT_STAMP" = "1" ]; then
    printf '%s\n' "$STAMP_CONTENT"
    exit 0
fi

# ---- preflight --------------------------------------------------------------

for tool in git cmake gcc g++ pkg-config patchelf readelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done

mkdir -p "$BUILD_DIR" "$LIBRARIES_DIR" "$LIBRARIES_SE2_DIR"

# ---- cache check ------------------------------------------------------------
# Only the build is cached; staging below always runs, so a wiped Libraries
# tree is repopulated without a rebuild.

PC_FILE="$SDL3_PREFIX/lib/pkgconfig/sdl3.pc"
SKIP_BUILD=0

if [ "$CLEAN" = "1" ]; then
    rm -rf "$SDL3_SRC_DIR" "$SDL3_PREFIX"
elif [ -f "$PC_FILE" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
    echo "==> Cached SDL3 matches $SDL3_TAG; skipping rebuild"
    echo "==> Prefix: $SDL3_PREFIX"
    SKIP_BUILD=1
fi

if [ "$SKIP_BUILD" = "0" ]; then

# ---- clone (cached) --------------------------------------------------------

if [ ! -d "$SDL3_SRC_DIR/.git" ]; then
    echo "==> Cloning $SDL3_REPO @ $SDL3_TAG -> $SDL3_SRC_DIR"
    rm -rf "$SDL3_SRC_DIR"
    git clone --branch "$SDL3_TAG" --depth 1 "$SDL3_REPO" "$SDL3_SRC_DIR"
else
    echo "==> Re-using cached clone at $SDL3_SRC_DIR"
    git -C "$SDL3_SRC_DIR" fetch --depth 1 origin "tag" "$SDL3_TAG" || true
    git -C "$SDL3_SRC_DIR" -c advice.detachedHead=false checkout "$SDL3_TAG"
fi

# ---- configure + build + install -------------------------------------------
# Tests and examples are off because nothing here runs them and they roughly
# double the build time. Everything else is upstream's default configuration
# for a Linux desktop build, with the two video drivers that matter turned on
# explicitly:
#
# SDL_X11 / SDL_WAYLAND are ON by default on Unix, but CMake quietly turns
# each off again when its development headers are missing — the same trap as
# OpenAL's audio backends. Passing them explicitly does not prevent that (SDL
# has no REQUIRE_* equivalent), so the generated SDL_build_config.h is
# asserted after the install instead.
#
# SDL_X11_SHARED / SDL_WAYLAND_SHARED (both ON by default) keep the display
# libraries dlopened rather than linked, so the shipped libSDL3.so needs
# nothing but glibc and adapts to whichever display server the user is on.
# The NEEDED check below enforces that.

echo "==> Configuring SDL3 $SDL3_VERSION -> $SDL3_PREFIX"
cmake -S "$SDL3_SRC_DIR" -B "$SDL3_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SDL3_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_TESTS=OFF \
    -DSDL_X11=ON \
    -DSDL_X11_SHARED=ON \
    -DSDL_WAYLAND=ON \
    -DSDL_WAYLAND_SHARED=ON \
    -DSDL_VULKAN=ON

echo "==> Building SDL3 with -j$JOBS"
cmake --build "$SDL3_BUILD_DIR" -j "$JOBS"

echo "==> Installing SDL3 into $SDL3_PREFIX"
cmake --install "$SDL3_BUILD_DIR" >/dev/null

[ -f "$PC_FILE" ] || {
    echo "ERROR: SDL3 install did not produce $PC_FILE" >&2
    echo "       DXVK resolves SDL3 through pkg-config, so the .pc file is" >&2
    echo "       what the DXVK build actually consumes." >&2
    exit 1
}

# ---- verify the video drivers ----------------------------------------------
# The whole point of shipping this library is that DXVK's SDL3 WSI driver can
# open a window on the user's machine. A build host without the X11 or Wayland
# headers produces an SDL that loads fine and then fails at SDL_CreateWindow,
# which is a miserable thing to debug downstream. Fail here instead.

CONFIG_HEADER="$(find "$SDL3_BUILD_DIR" -name SDL_build_config.h -print -quit)"
[ -n "$CONFIG_HEADER" ] || {
    echo "ERROR: could not locate the generated SDL_build_config.h under" >&2
    echo "       $SDL3_BUILD_DIR" >&2
    exit 1
}

DRIVER_MISSING=0
for driver in SDL_VIDEO_DRIVER_X11 SDL_VIDEO_DRIVER_WAYLAND SDL_VIDEO_VULKAN; do
    if ! grep -qE "^#define $driver 1\$" "$CONFIG_HEADER"; then
        echo "  not enabled: $driver" >&2
        DRIVER_MISSING=1
    fi
done
if [ "$DRIVER_MISSING" = "1" ]; then
    echo "ERROR: SDL3 was configured without a video driver we ship for." >&2
    echo "       CMake disables X11/Wayland silently when their development" >&2
    echo "       headers are absent. Install them and rebuild --clean; see" >&2
    echo "       docs/building.md for the package list." >&2
    echo "       Config header: $CONFIG_HEADER" >&2
    exit 1
fi
echo "==> Video drivers present: X11, Wayland, Vulkan"

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

fi  # SKIP_BUILD

# ---- verify the SONAME ------------------------------------------------------
# DXVK dlopens "libSDL3.so.0" by name; the shipped file is libSDL3.so, so the
# dlopen only resolves to it because the consumer preloads the file first and
# the SONAME inside it matches. A bump here would silently leave the bundled
# copy unused.

REAL_LIB="$(readlink -f "$SDL3_PREFIX/lib/libSDL3.so")"
[ -f "$REAL_LIB" ] || {
    echo "ERROR: $SDL3_PREFIX/lib/libSDL3.so missing after install" >&2
    exit 1
}

SONAME="$(readelf -d "$REAL_LIB" 2>/dev/null \
          | awk '/\(SONAME\)/ {match($0, /\[.*\]/); print substr($0, RSTART+1, RLENGTH-2)}')"
if [ "$SONAME" != "$EXPECTED_SONAME" ]; then
    echo "ERROR: expected SONAME '$EXPECTED_SONAME', got '$SONAME'." >&2
    echo "       DXVK dlopens the old name, so a bump means the bundled" >&2
    echo "       library is never used. Update EXPECTED_SONAME here, the" >&2
    echo "       expected-file lists in build.sh, and the consumers together." >&2
    exit 1
fi

# ---- patch DT_RUNPATH=$ORIGIN ----------------------------------------------
# Parity with the FFmpeg, DXVK and OpenAL payloads. Patch a private copy so
# the prefix that DXVK compiles against stays exactly as installed.

STAGE_LIB="$BUILD_DIR/libSDL3.so.staged"
install -m 0755 "$REAL_LIB" "$STAGE_LIB"

echo "==> Patching DT_RUNPATH=\$ORIGIN onto libSDL3"
patchelf --set-rpath '$ORIGIN' "$STAGE_LIB"

# ---- verify runtime dependencies -------------------------------------------
# X11, Wayland, xkbcommon, libdecor, libdrm/gbm, the audio backends and Vulkan
# are all dlopened by SDL at runtime, so none of them may appear as a NEEDED
# entry: one that did would make the whole bundle hard-require that display or
# audio stack on every user's machine.

echo "==> Verifying minimal runtime dependencies"
ALLOWED_RE='^(linux-vdso|ld-linux|libc|libm|libpthread|libdl|librt|libgcc_s|libstdc\+\+|libatomic)(-[a-z0-9_.-]+)?\.so'
DEP_LEAK=0
while IFS= read -r line; do
    bare="$(printf '%s' "$line" | awk '{print $1}')"
    bare="${bare##*/}"
    [ -z "$bare" ] && continue
    if ! [[ "$bare" =~ $ALLOWED_RE ]]; then
        echo "  unexpected dep: $bare" >&2
        DEP_LEAK=1
    fi
done < <(ldd "$STAGE_LIB" | sed 's/^[[:space:]]*//')
if [ "$DEP_LEAK" = "1" ]; then
    echo "ERROR: libSDL3 has an unexpected runtime dependency." >&2
    echo "       Display and audio backends are meant to be dlopened, not" >&2
    echo "       linked. Check that SDL_X11_SHARED / SDL_WAYLAND_SHARED and" >&2
    echo "       the other SDL_*_SHARED options are still ON." >&2
    exit 1
fi

# ---- stage ------------------------------------------------------------------
# Ship the real file under the bare unversioned name — the archives carry no
# symlinks and no version-suffixed filenames. Both game archives get the same
# bytes: SE1's DXVK and SE2's DXVK are the same build and dlopen the same name.
# Clear any previous build's files first so a version bump cannot leave a
# stale copy behind.

for dest in "$LIBRARIES_DIR" "$LIBRARIES_SE2_DIR"; do
    echo "==> Staging SDL3 into $dest"
    find "$dest" -maxdepth 1 -name 'libSDL3.so*' -delete
    install -m 0755 "$STAGE_LIB" "$dest/libSDL3.so"
done

rm -f "$STAGE_LIB"

echo
echo "==> SDL3 $SDL3_VERSION available at $SDL3_PREFIX"
PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig" pkg-config --modversion sdl3
echo "==> Staged libSDL3.so into $LIBRARIES_DIR and $LIBRARIES_SE2_DIR"
