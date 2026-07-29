#!/usr/bin/env bash
# build_sdl3.sh
#
# Builds SDL3 from upstream sources into a build-local prefix, purely so that
# DXVK Native has SDL3 headers and a pkg-config file to compile against.
#
# SDL3 is NOT a shipped artefact. DXVK's meson build takes it as
#
#     lib_sdl3.partial_dependency(compile_args: true, includes: true)
#
# i.e. headers and compile flags only — the produced libdxvk_*.so have no
# NEEDED entry for libSDL3 and dlopen "libSDL3.so.0" at runtime instead. Pulsar
# supplies SDL3 from the user's system (it sets DXVK_WSI_DRIVER=SDL3 and
# preloads libSDL3.so; see Legacy/Loader/NativeLibraryPreloader.cs there), so
# nothing about SDL3 needs to end up in our release archive.
#
# Why build it instead of using the host's SDL3: Ubuntu 24.04 — the pinned CI
# runner image — has no libsdl3-dev package at all, and a developer machine may
# have any SDL3 version or none. Building one pinned version here means CI and
# local builds compile DXVK against identical headers.
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── SDL/                shallow clone of libsdl-org/SDL at the pinned tag
#   ├── sdl3-prefix/        install prefix (headers + lib + pkgconfig)
#   └── sdl3.stamp          last-built tag (cache key)
#
# Usage:
#   ./build_sdl3.sh           Build (or no-op if cached).
#   ./build_sdl3.sh --clean   Wipe build dirs and rebuild from scratch.
#
# On success the prefix is at $SDL3_PREFIX and its pkgconfig dir is
# $SDL3_PREFIX/lib/pkgconfig (build_dxvk.sh prepends that to PKG_CONFIG_PATH).
#
# Env-var overrides (defaults shown):
#   SDL3_VERSION = 3.4.12   (upstream tag is release-$SDL3_VERSION)
#   SDL3_REPO    = https://github.com/libsdl-org/SDL.git
#   BUILD_DIR    = <repo>/build
#   SDL3_PREFIX  = $BUILD_DIR/sdl3-prefix
#   JOBS         = $(nproc)
#
# Requirements: git, cmake, ninja (or make), gcc, g++, pkg-config.

set -euo pipefail

SDL3_VERSION="${SDL3_VERSION:-3.4.12}"
SDL3_REPO="${SDL3_REPO:-https://github.com/libsdl-org/SDL.git}"
SDL3_TAG="release-$SDL3_VERSION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"
SDL3_PREFIX="${SDL3_PREFIX:-$BUILD_DIR/sdl3-prefix}"
JOBS="${JOBS:-$(nproc)}"

SDL3_SRC_DIR="$BUILD_DIR/SDL"
SDL3_BUILD_DIR="$SDL3_SRC_DIR/_build"
STAMP_FILE="$BUILD_DIR/sdl3.stamp"

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean)   CLEAN=1 ;;
        -h|--help) sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ---- preflight --------------------------------------------------------------

for tool in git cmake gcc g++ pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done

mkdir -p "$BUILD_DIR"

# ---- cache check ------------------------------------------------------------

PC_FILE="$SDL3_PREFIX/lib/pkgconfig/sdl3.pc"

if [ "$CLEAN" = "1" ]; then
    rm -rf "$SDL3_SRC_DIR" "$SDL3_PREFIX"
elif [ -f "$PC_FILE" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$SDL3_TAG" ]; then
    echo "==> Cached SDL3 matches $SDL3_TAG; skipping rebuild"
    echo "==> Prefix: $SDL3_PREFIX"
    exit 0
fi

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
# Only the shared library, headers and pkg-config file are wanted. Tests and
# examples are off because nothing here runs them and they roughly double the
# build time.

echo "==> Configuring SDL3 $SDL3_VERSION -> $SDL3_PREFIX"
cmake -S "$SDL3_SRC_DIR" -B "$SDL3_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$SDL3_PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_INSTALL_TESTS=OFF

echo "==> Building SDL3 with -j$JOBS"
cmake --build "$SDL3_BUILD_DIR" -j "$JOBS"

echo "==> Installing SDL3 into $SDL3_PREFIX"
cmake --install "$SDL3_BUILD_DIR" >/dev/null

[ -f "$PC_FILE" ] || {
    echo "ERROR: SDL3 install did not produce $PC_FILE" >&2
    echo "       DXVK resolves SDL3 through pkg-config, so the .pc file is" >&2
    echo "       the part that actually matters here." >&2
    exit 1
}

printf '%s\n' "$SDL3_TAG" > "$STAMP_FILE"

echo
echo "==> SDL3 $SDL3_VERSION available at $SDL3_PREFIX"
PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig" pkg-config --modversion sdl3
