#!/usr/bin/env bash
# build_dxc.sh
#
# Builds the DirectX Shader Compiler (DXC) from upstream sources at
# https://github.com/microsoft/DirectXShaderCompiler, applies the SE2 ABI
# compatibility patch, and installs it into build/Libraries-SE2:
#
#   libdxcompiler.so        patched DXC, built from source
#
# Space Engineers 2 compiles every shader through Vortice.Dxc, which
# P/Invokes DxcCreateInstance from "dxcompiler.dll". DXC's Linux WCHAR is a
# 4-byte wchar_t while Vortice marshals the Windows 2-byte wire type, so the
# patch converts strings in IDxcCompiler3, IDxcResult and the include-handler
# callback at that boundary. Building DXC with -fshort-wchar instead
# is not an option — libdxcompiler.so imports
# eight wide-char functions from glibc (wcslen, wcscmp, wcsncmp, wcsncpy,
# wmemcmp, wmemcpy, mbstowcs, wcstombs) and a 2-byte wchar_t build would
# silently mismatch every one of them.
#
# libdxil.so is deliberately NOT shipped. Microsoft open-sourced the DXIL
# validator hash, so ComputeHashRetail is compiled directly into
# libdxcompiler.so; compiling with and without libdxil.so beside it produces
# byte-identical containers with the same non-zero DXIL hash, and LD_DEBUG
# shows it is never dlopened. It is also not buildable from source — it only
# exists as a prebuilt release artefact — so dropping it is what makes a
# pure from-source build possible.
#
# The pin is the latest *stable* release. The v1.10.x line is the Shader
# Model 6.10 preview: every v1.10 release is flagged as a prerelease upstream,
# and v1.10.2605.24 was observed aborting inside LLVM (User::allocHungoffUses)
# while compiling SE2's Render12 shaders. Do not bump onto it.
#
# SE2 never passes -spirv, so the SPIR-V backend is dead weight here, but it
# cannot be switched off: DXC's root CMakeLists.txt does an unconditional
# `if(NOT WIN32) set(ENABLE_SPIRV_CODEGEN ON) endif()` that shadows both the
# cache and the command line. Building it is therefore not optional on Linux,
# and external/SPIRV-Headers + external/SPIRV-Tools have to be initialised
# along with external/DirectX-Headers. Only the test suites are skipped, which
# is what keeps external/googletest uncloned.
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── Libraries-SE2/             SE2 staging dir this script populates
#   ├── dxc/                       clone at the pinned tag (~250 MB)
#   │   └── build/                 cmake/ninja build tree (~270 MB, deleted
#   │                              after staging unless DXC_KEEP_BUILD_TREE=1)
#   └── dxc.stamp                  last-built commit + patch-series hash
#
# Usage:
#   ./build_dxc.sh           Build (or no-op if cached).
#   ./build_dxc.sh --clean   Wipe build dirs and rebuild from scratch.
#   ./build_dxc.sh --print-stamp
#                            Print this build's cache stamp and exit without
#                            touching the network. The value is the content key
#                            CI caches the staged libraries under; see
#                            docs/building.md.
#
# Env-var overrides (defaults shown):
#   DXC_TAG               = v1.9.2607
#   DXC_COMMIT            = 0d3ee6b551b8fa768fbf825300ebab81047ef6a8
#   DXC_REPO              = https://github.com/microsoft/DirectXShaderCompiler.git
#   DXC_KEEP_BUILD_TREE   = 0   (1 keeps the cmake build tree around)
#   BUILD_DIR             = <repo>/build
#   LIBRARIES_SE2_DIR     = $BUILD_DIR/Libraries-SE2
#   JOBS                  = $(nproc)
#
# Requirements: git, cmake (>=3.20), ninja, python3, gcc, g++.
# A full DXC build is about 19 minutes on a GitHub-hosted 4-vCPU runner and
# proportionally less on more cores — still several times the rest of the
# pipeline put together. Building only the dxcompiler target in release with
# assertions off keeps the peak footprint around 550 MB, which is what makes
# it fit on a hosted runner's 14 GB disk.

set -euo pipefail

DXC_TAG="${DXC_TAG:-v1.9.2607}"
DXC_COMMIT="${DXC_COMMIT:-0d3ee6b551b8fa768fbf825300ebab81047ef6a8}"
DXC_REPO="${DXC_REPO:-https://github.com/microsoft/DirectXShaderCompiler.git}"
DXC_KEEP_BUILD_TREE="${DXC_KEEP_BUILD_TREE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR_DEFAULT="$REPO_DIR/build"

BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"
LIBRARIES_SE2_DIR="${LIBRARIES_SE2_DIR:-$BUILD_DIR/Libraries-SE2}"
JOBS="${JOBS:-$(nproc)}"

PATCHES_DIR="$REPO_DIR/Patches/dxc"

SRC_DIR="$BUILD_DIR/dxc"
CMAKE_BUILD_DIR="$SRC_DIR/build"
STAMP_FILE="$BUILD_DIR/dxc.stamp"

EXPECTED_LIBS=(libdxcompiler.so)

CLEAN=0
PRINT_STAMP=0
for arg in "$@"; do
    case "$arg" in
        --clean)       CLEAN=1 ;;
        --print-stamp) PRINT_STAMP=1 ;;
        -h|--help) sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Apply and hash patches in deterministic order.
PATCH_FILES=()
if [ -d "$PATCHES_DIR" ]; then
    while IFS= read -r p; do
        PATCH_FILES+=("$p")
    done < <(find "$PATCHES_DIR" -maxdepth 1 -name '*.patch' | LC_ALL=C sort)
fi
if [ "${#PATCH_FILES[@]}" -gt 0 ]; then
    PATCH_HASH="$(cat "${PATCH_FILES[@]}" | sha256sum | cut -d' ' -f1)"
else
    PATCH_HASH="no-patches"
fi
STAMP_CONTENT="$DXC_COMMIT patches=$PATCH_HASH"

if [ "$PRINT_STAMP" = "1" ]; then
    printf '%s\n' "$STAMP_CONTENT"
    exit 0
fi

# ---- preflight --------------------------------------------------------------

for tool in git cmake ninja python3 gcc g++; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done

CMAKE_VERSION="$(cmake --version | head -1 | awk '{print $3}')"
if [ "$(printf '%s\n3.20.0\n' "$CMAKE_VERSION" | sort -V | head -1)" != "3.20.0" ]; then
    echo "ERROR: cmake >= 3.20 required, found $CMAKE_VERSION" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$LIBRARIES_SE2_DIR"

# ---- cache check ------------------------------------------------------------

ALL_LIBS_PRESENT=1
for lib in "${EXPECTED_LIBS[@]}"; do
    [ -e "$LIBRARIES_SE2_DIR/$lib" ] || ALL_LIBS_PRESENT=0
done

if [ "$CLEAN" = "1" ]; then
    rm -rf "$SRC_DIR"
elif [ "$ALL_LIBS_PRESENT" = "1" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
    echo "==> Cached build matches DXC $DXC_TAG (${DXC_COMMIT:0:12}); skipping rebuild"
    echo "==> DXC libs already in $LIBRARIES_SE2_DIR:"
    ( cd "$LIBRARIES_SE2_DIR" && ls -1 libdxcompiler.so )
    exit 0
fi

# ---- clone (cached) ---------------------------------------------------------
# The tag ref is fetched (not just the bare SHA) because DXC's cmake cache
# enables LLVM_APPEND_VC_REV, which runs `git describe` to stamp the release
# tag into the library's version string. A SHA-only shallow clone has no tags
# and the .so would self-report as an untagged build. The pinned SHA is then
# asserted against what the tag actually resolves to, so a moved tag fails
# the build instead of silently shipping something else.

if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> Fetching $DXC_REPO @ $DXC_TAG -> $SRC_DIR"
    rm -rf "$SRC_DIR"
    git init -q "$SRC_DIR"
    git -C "$SRC_DIR" remote add origin "$DXC_REPO"
fi
if ! git -C "$SRC_DIR" cat-file -e "$DXC_COMMIT^{commit}" 2>/dev/null; then
    git -C "$SRC_DIR" fetch --depth 1 origin "refs/tags/$DXC_TAG:refs/tags/$DXC_TAG"
fi
git -C "$SRC_DIR" -c advice.detachedHead=false checkout "refs/tags/$DXC_TAG"

ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$DXC_COMMIT" ]; then
    echo "ERROR: tag $DXC_TAG resolves to $ACTUAL_COMMIT," >&2
    echo "       but the pin in this script is $DXC_COMMIT." >&2
    echo "       The upstream tag was moved; see docs/maintenance.md." >&2
    exit 1
fi

echo "==> Resetting DXC source tree to pristine $DXC_TAG (${DXC_COMMIT:0:12})"
git -C "$SRC_DIR" checkout -- .
git -C "$SRC_DIR" clean -fdxe build --quiet

if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
    echo "==> No patches under $PATCHES_DIR; building pristine upstream"
fi
for p in ${PATCH_FILES[@]+"${PATCH_FILES[@]}"}; do
    echo "==> Applying $(basename "$p")"
    if ! git -C "$SRC_DIR" apply "$p"; then
        echo "ERROR: patch failed to apply: $p" >&2
        echo "       The series under Patches/dxc/ needs a rebase onto" >&2
        echo "       DXC $DXC_TAG. See docs/maintenance.md." >&2
        exit 1
    fi
done

# DirectX-Headers is required on every non-Windows target (reflection
# support); the two SPIRV-* modules are required because upstream forces the
# SPIR-V backend on for non-Windows builds (see the header comment).
# external/googletest is deliberately left uninitialised - it is only used by
# the test suites, which are off below.
for module in external/DirectX-Headers external/SPIRV-Headers external/SPIRV-Tools; do
    git -C "$SRC_DIR" submodule update --init --depth 1 "$module"
done

# ---- build libdxcompiler.so -------------------------------------------------
# PredefinedParams.cmake is DXC's own "build dxc the way we build dxc" cache
# file. Its set()s are non-FORCE, so a -D on the command line wins over it --
# but only when the -D comes BEFORE the -C, which is why the flag order here
# is not cosmetic. Only the dxcompiler target is built: the dxc driver
# executable and the test suites are dead weight for the shipped payload.

echo "==> Configuring DXC (release, no tests)"
cmake -S "$SRC_DIR" -B "$CMAKE_BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DSPIRV_BUILD_TESTS=OFF \
    -DHLSL_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -C "$SRC_DIR/cmake/caches/PredefinedParams.cmake"

echo "==> Building DXC (tens of minutes; ~19 on 4 cores)"
ninja -C "$CMAKE_BUILD_DIR" -j "$JOBS" dxcompiler

DXCOMPILER_SO="$(find -L "$CMAKE_BUILD_DIR" -type f -name libdxcompiler.so -print -quit)"
if [ -z "$DXCOMPILER_SO" ]; then
    echo "ERROR: the build did not produce libdxcompiler.so under $CMAKE_BUILD_DIR" >&2
    exit 1
fi

# ---- stage ------------------------------------------------------------------

echo "==> Staging DXC into $LIBRARIES_SE2_DIR"
install -m 0755 "$DXCOMPILER_SO" "$LIBRARIES_SE2_DIR/libdxcompiler.so"
rm -f "$LIBRARIES_SE2_DIR/libSE2DxcCompiler.so"

# ---- verify the configured version ------------------------------------------
# LLVM_APPEND_VC_REV makes the configure step run `git describe` and fold the
# result into PACKAGE_VERSION. Checking the generated header confirms the
# build really was configured against the pinned tag -- a shallow clone with
# no tags, or a checkout that silently drifted, shows up here rather than in
# a consumer weeks later.
#
# The corresponding runtime string is NOT checkable with `strings` on the
# finished .so: the version literals end up in an unterminated, 16-byte
# merged constant pool, where the tag reads back truncated ("3.7-v1.9.26").

CONFIG_H="$CMAKE_BUILD_DIR/include/llvm/Config/config.h"
CONFIGURED_VERSION="$(sed -n 's/^#define PACKAGE_VERSION "\(.*\)"$/\1/p' "$CONFIG_H")"
EXPECTED_CONFIGURED_VERSION="3.7-$DXC_TAG"
if [ "${#PATCH_FILES[@]}" -gt 0 ]; then
    EXPECTED_CONFIGURED_VERSION+="-dirty"
fi
if [ "$CONFIGURED_VERSION" != "$EXPECTED_CONFIGURED_VERSION" ]; then
    echo "ERROR: DXC configured itself as PACKAGE_VERSION '$CONFIGURED_VERSION'," >&2
    echo "       expected '$EXPECTED_CONFIGURED_VERSION'. The source tree is not at the pinned tag." >&2
    exit 1
fi
echo "==> DXC configured version: $CONFIGURED_VERSION"

# ---- drop the build tree ----------------------------------------------------
# ~270 MB of object files and static archives that nothing downstream reads.
# The clone itself stays to avoid another network fetch on the next build.

if [ "$DXC_KEEP_BUILD_TREE" = "1" ]; then
    echo "==> Keeping the DXC build tree (DXC_KEEP_BUILD_TREE=1): $CMAKE_BUILD_DIR"
else
    echo "==> Removing the DXC build tree ($(du -sh "$CMAKE_BUILD_DIR" | cut -f1))"
    rm -rf "$CMAKE_BUILD_DIR"
fi

# ---- update cache stamp -----------------------------------------------------

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

echo
echo "==> Staged DXC into $LIBRARIES_SE2_DIR:"
( cd "$LIBRARIES_SE2_DIR" && ls -1 libdxcompiler.so )
