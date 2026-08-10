#!/usr/bin/env bash
# build_dxvk.sh
#
# Builds DXVK Native (the ELF/Linux variant of DXVK) from upstream sources
# at https://github.com/doitsujin/dxvk, then installs the two .so files
# the Space Engineers client needs into the staging folder:
#
#   libdxvk_d3d11.so   (SONAME libdxvk_d3d11.so.0; we ship both via a symlink)
#   libdxvk_dxgi.so    (SONAME libdxvk_dxgi.so.0;  same)
#
# Two variants are built from the same pinned tag:
#
#   SE1 (default)   Pristine upstream sources, staged into build/Libraries/.
#                   Shipped in linux-dependencies.tar.gz for Space Engineers 1
#                   (Pulsar for Linux).
#   SE2 (--se2)     Upstream sources with the patch series under Patches/dxvk/
#                   applied first, staged into build/Libraries-SE2/. Shipped in
#                   linux-dependencies-se2.tar.gz for the Space Engineers 2
#                   client, which needs source-level DXVK fixes instead of
#                   managed (Harmony) workarounds.
#
# DXVK Native is built by running upstream's package-native.sh helper at the
# pinned tag; we pass --64-only --no-package so the 32-bit build is skipped
# (Space Engineers is x86_64-only) and the .tar.gz packaging step is skipped
# (we only need the installed .so files).
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── Libraries/                 SE1 staging dir all dep scripts populate
#   ├── Libraries-SE2/             SE2 staging dir (--se2)
#   ├── dxvk/                      shallow clone of doitsujin/dxvk at tag (SE1)
#   ├── dxvk-out/                  package-native.sh destdir (SE1, recreated)
#   ├── dxvk.stamp                 last-built SE1 tag (cache key)
#   ├── dxvk-se2/                  separate clone for the patched SE2 build
#   ├── dxvk-se2-out/              package-native.sh destdir (SE2, recreated)
#   └── dxvk-se2.stamp             last-built SE2 tag + patch-series hash
#
# The SE2 variant uses its own clone rather than resetting the SE1 one, so a
# patched tree can never leak into the pristine SE1 build (or vice versa) and
# each variant stays independently cached.
#
# Usage:
#   ./build_dxvk.sh           Build the SE1 variant (or no-op if cached).
#   ./build_dxvk.sh --se2     Build the SE2 variant with Patches/dxvk/ applied.
#   ./build_dxvk.sh --clean   Wipe the variant's build dirs and rebuild.
#
# SDL3 is required to build (see build_sdl3.sh, which this script invokes):
# DXVK Native's window-system integration compiles against SDL3 headers and
# dlopens libSDL3.so.0 at runtime. Ubuntu 24.04 has no libsdl3-dev package, so
# a pinned SDL3 is built into build/sdl3-prefix/ and put on PKG_CONFIG_PATH
# here. Nothing from SDL3 ends up in the release archives.
#
# Env-var overrides (defaults shown):
#   DXVK_VERSION      = 2.7.1
#   DXVK_REPO         = https://github.com/doitsujin/dxvk.git
#   BUILD_DIR         = <repo>/build
#   LIBRARIES_DIR     = $BUILD_DIR/Libraries       (SE1 staging dir)
#   LIBRARIES_SE2_DIR = $BUILD_DIR/Libraries-SE2   (SE2 staging dir)
#   SDL3_PREFIX       = $BUILD_DIR/sdl3-prefix
#   JOBS              = $(nproc)
#
# Requirements: git, meson (>=0.58), ninja, glslang (glslangValidator),
# pkg-config, gcc, g++, patchelf, cmake (for the SDL3 build).
# Typical Debian/Ubuntu install:
#   sudo apt install git meson ninja-build glslang-tools libvulkan-dev \
#                    pkg-config build-essential patchelf cmake

set -euo pipefail

DXVK_VERSION="${DXVK_VERSION:-2.7.1}"
DXVK_REPO="${DXVK_REPO:-https://github.com/doitsujin/dxvk.git}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR_DEFAULT="$REPO_DIR/build"

BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"
LIBRARIES_DIR="${LIBRARIES_DIR:-$BUILD_DIR/Libraries}"
LIBRARIES_SE2_DIR="${LIBRARIES_SE2_DIR:-$BUILD_DIR/Libraries-SE2}"
SDL3_PREFIX="${SDL3_PREFIX:-$BUILD_DIR/sdl3-prefix}"
JOBS="${JOBS:-$(nproc)}"

PATCHES_DIR="$REPO_DIR/Patches/dxvk"

EXPECTED_LIBS=(libdxvk_d3d11.so libdxvk_dxgi.so)

# What the cache check must find for a rebuild to be skippable: the libraries
# AND the SONAME aliases, because build.sh asserts on the aliases too. Checking
# only the bare .so names would let a missing libdxvk_d3d11.so.0 report
# "cached, skipping rebuild" and then fail the caller's assertion, recoverable
# only by a full ~10-minute --clean rebuild.
EXPECTED_STAGED=(
    libdxvk_d3d11.so libdxvk_d3d11.so.0
    libdxvk_dxgi.so  libdxvk_dxgi.so.0
)

CLEAN=0
VARIANT=se1
for arg in "$@"; do
    case "$arg" in
        --clean)   CLEAN=1 ;;
        --se2)     VARIANT=se2 ;;
        -h|--help) sed -n '2,68p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ---- variant wiring ---------------------------------------------------------

if [ "$VARIANT" = "se2" ]; then
    DXVK_SRC_DIR="$BUILD_DIR/dxvk-se2"
    DXVK_OUT_DIR="$BUILD_DIR/dxvk-se2-out"
    STAMP_FILE="$BUILD_DIR/dxvk-se2.stamp"
    STAGE_DIR="$LIBRARIES_SE2_DIR"
else
    DXVK_SRC_DIR="$BUILD_DIR/dxvk"
    DXVK_OUT_DIR="$BUILD_DIR/dxvk-out"
    STAMP_FILE="$BUILD_DIR/dxvk.stamp"
    STAGE_DIR="$LIBRARIES_DIR"
fi

# The patch series is part of the SE2 cache key: adding, editing or removing a
# patch must invalidate the cached build. LC_ALL=C pins the sort order so the
# hash does not depend on the host locale. An empty (or absent) series is
# valid — the SE2 build is then upstream DXVK, staged separately.
PATCH_FILES=()
if [ "$VARIANT" = "se2" ] && [ -d "$PATCHES_DIR" ]; then
    while IFS= read -r p; do
        PATCH_FILES+=("$p")
    done < <(find "$PATCHES_DIR" -maxdepth 1 -name '*.patch' | LC_ALL=C sort)
fi

if [ "$VARIANT" = "se2" ]; then
    if [ "${#PATCH_FILES[@]}" -gt 0 ]; then
        PATCH_HASH="$(cat "${PATCH_FILES[@]}" | sha256sum | cut -d' ' -f1)"
    else
        PATCH_HASH="no-patches"
    fi
    STAMP_CONTENT="$DXVK_VERSION patches=$PATCH_HASH"
else
    STAMP_CONTENT="$DXVK_VERSION"
fi

# ---- preflight --------------------------------------------------------------

for tool in git meson ninja glslangValidator pkg-config gcc g++ patchelf cmake; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done

mkdir -p "$BUILD_DIR" "$STAGE_DIR"

# ---- cache check ------------------------------------------------------------

ALL_LIBS_PRESENT=1
for lib in "${EXPECTED_STAGED[@]}"; do
    [ -e "$STAGE_DIR/$lib" ] || ALL_LIBS_PRESENT=0
done

if [ "$CLEAN" = "1" ]; then
    rm -rf "$DXVK_SRC_DIR" "$DXVK_OUT_DIR"
elif [ "$ALL_LIBS_PRESENT" = "1" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
    echo "==> Cached build matches DXVK $DXVK_VERSION ($VARIANT); skipping rebuild"
    echo "==> DXVK libs already in $STAGE_DIR:"
    ( cd "$STAGE_DIR" && ls -1 libdxvk_*.so* )
    exit 0
fi

# ---- clone (cached) --------------------------------------------------------

if [ ! -d "$DXVK_SRC_DIR/.git" ]; then
    echo "==> Cloning $DXVK_REPO @ v$DXVK_VERSION -> $DXVK_SRC_DIR"
    rm -rf "$DXVK_SRC_DIR"
    git clone --branch "v$DXVK_VERSION" --depth 1 --recurse-submodules \
        --shallow-submodules "$DXVK_REPO" "$DXVK_SRC_DIR"
else
    echo "==> Re-using cached clone at $DXVK_SRC_DIR"
    git -C "$DXVK_SRC_DIR" fetch --depth 1 origin "tag" "v$DXVK_VERSION" || true
    git -C "$DXVK_SRC_DIR" -c advice.detachedHead=false checkout "v$DXVK_VERSION"
    git -C "$DXVK_SRC_DIR" submodule update --init --recursive --depth 1
fi

# ---- SE2 only: reset to pristine, then apply the patch series ---------------
# The clone is cached across runs, so before applying patches the tree is
# forced back to the pristine tag state — a previous run's applied patches (or
# an edited series) would otherwise stack or conflict. This forfeits ninja
# incrementality for the SE2 variant (clean -fdx removes the meson build
# dirs), which is the price of a guaranteed pristine base for every series.

if [ "$VARIANT" = "se2" ]; then
    echo "==> Resetting DXVK source tree to pristine v$DXVK_VERSION"
    git -C "$DXVK_SRC_DIR" checkout -- .
    git -C "$DXVK_SRC_DIR" clean -fdx --quiet
    git -C "$DXVK_SRC_DIR" submodule foreach --recursive --quiet \
        'git checkout -- . && git clean -fdx --quiet'

    if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
        echo "==> No patches under $PATCHES_DIR; SE2 build is pristine upstream"
    fi
    for p in ${PATCH_FILES[@]+"${PATCH_FILES[@]}"}; do
        echo "==> Applying $(basename "$p")"
        if ! git -C "$DXVK_SRC_DIR" apply "$p"; then
            echo "ERROR: patch failed to apply: $p" >&2
            echo "       The series under Patches/dxvk/ needs a rebase onto" >&2
            echo "       DXVK v$DXVK_VERSION. See docs/maintenance.md." >&2
            exit 1
        fi
    done
fi

# ---- SDL3 (build-time only) -------------------------------------------------
# DXVK's meson build errors out with "SDL3, SDL2, or GLFW are required to build
# dxvk-native" unless one of them is discoverable. Build the pinned SDL3 and
# put its pkgconfig dir first on PKG_CONFIG_PATH, so the same headers are used
# whether or not the host happens to have an SDL3 installed.

SDL3_ARGS=()
if [ "$CLEAN" = "1" ]; then
    SDL3_ARGS+=("--clean")
fi

echo "==> Ensuring SDL3 is available for the DXVK build"
bash "$SCRIPT_DIR/build_sdl3.sh" "${SDL3_ARGS[@]+"${SDL3_ARGS[@]}"}"

export PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# ---- build via upstream package-native.sh ----------------------------------
# package-native.sh refuses to run if its destdir/dxvk-native-<ver>/ already
# exists, so wipe the destdir on every run. The package-native.sh body is
# tiny (<200 lines) and stable across recent DXVK versions; we shell out to
# it verbatim rather than re-implementing the meson invocation, so any
# future upstream tweaks (extra meson flags, etc.) just work.

rm -rf "$DXVK_OUT_DIR"
mkdir -p "$DXVK_OUT_DIR"

echo "==> Running DXVK package-native.sh (64-only, no-package, $VARIANT)"
(
    cd "$DXVK_SRC_DIR"
    NINJA_OPTS="-j$JOBS" \
        ./package-native.sh "$DXVK_VERSION" "$DXVK_OUT_DIR" --64-only --no-package
)

# ---- locate + stage the .so outputs ----------------------------------------
# package-native.sh installs into $DXVK_OUT_DIR/dxvk-native-$DXVK_VERSION/usr/lib/.
# We `find` rather than hard-code the path so a future upstream rearrangement
# (e.g. usr/lib64/, multiarch subdir) doesn't silently break the script.

echo "==> Staging DXVK libs into $STAGE_DIR"
for lib in "${EXPECTED_LIBS[@]}"; do
    # `-L` so find follows the unversioned .so symlink chain to the real
    # versioned file (libdxvk_*.so -> libdxvk_*.so.0 -> libdxvk_*.so.0.<ver>).
    # `install` then copies the dereferenced file under the bare .so name,
    # matching the pre-existing Libraries/ layout.
    src="$(find -L "$DXVK_OUT_DIR" -type f -name "$lib" -print -quit)"
    if [ -z "$src" ]; then
        echo "ERROR: package-native.sh did not produce $lib under $DXVK_OUT_DIR" >&2
        exit 1
    fi
    install -m 0755 "$src" "$STAGE_DIR/$lib"
    # Recreate the SONAME alias as a symlink so anything dlopen()ing the
    # SONAME directly (rare, but matches the pre-existing layout) finds it.
    ln -sfn "$lib" "$STAGE_DIR/${lib}.0"
done

# ---- patch DT_RUNPATH=$ORIGIN onto each .so --------------------------------
# Parity with the FFmpeg payload: with DT_RUNPATH=$ORIGIN baked in, ld.so
# resolves any cross-DXVK NEEDED entries (e.g. libdxvk_d3d11 -> libdxvk_dxgi)
# via the loaded lib's own directory, so the consumer's launcher doesn't need
# to prepend Bin/ to LD_LIBRARY_PATH.

echo "==> Patching DT_RUNPATH=\$ORIGIN onto DXVK libs"
for lib in "${EXPECTED_LIBS[@]}"; do
    patchelf --set-rpath '$ORIGIN' "$STAGE_DIR/$lib"
done

# ---- update cache stamp ----------------------------------------------------

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

echo
echo "==> Staged DXVK libs ($VARIANT) into $STAGE_DIR:"
( cd "$STAGE_DIR" && ls -1 libdxvk_*.so* )
