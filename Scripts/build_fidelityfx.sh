#!/usr/bin/env bash
# build_fidelityfx.sh
#
# Builds AMD's FidelityFX FSR 3.1.5 upscaler as a native Linux shared library
# and installs it into build/Libraries-SE2:
#
#   libamd_fidelityfx_loader_dx12.so
#
# Space Engineers 2's renderer P/Invokes five entry points -- ffxCreateContext,
# ffxDestroyContext, ffxConfigure, ffxQuery and ffxDispatch -- from
# "amd_fidelityfx_loader_dx12.dll" when the graphics Quality setting selects
# FSR upscaling. That is AMD's flat "ffx_api" ABI: plain C functions taking
# struct chains, with vkd3d-proton's own ID3D12Device* and ID3D12Resource*
# pointers passed straight through. No Windows ABI crosses the boundary, so a
# native SysV .so exporting those five symbols works as-is.
#
# The library is a single object: AMD's ffx_api dispatcher, the DX12 backend
# and the FSR 3.1.5 provider are all linked into it. AMD's Windows build
# discovers providers by loading separate upscaler DLLs; statically linking the
# one provider we can build from source sidesteps that machinery entirely.
#
# Only FSR 3.1.5 is included. FSR 4.x ships as a prebuilt, signed Windows DLL
# with no source, and the driver-side provider lives in AMD's closed
# "amdinternal" tree, so neither can be part of a from-source Linux build. The
# plugin forces the game's ForceUseFSR_3_1 setting on to match.
#
# Two upstream checkouts are needed:
#
#   v2.3.0  the SDK itself: the ffx_api dispatcher, the DX12 backend and the
#           FSR 3.1.5 upscaler, including its HLSL sources.
#   v1.1.4  the source of FidelityFX_SC, the shader permutation compiler. The
#           2.x releases ship it only as a prebuilt Windows .exe, and the
#           generated permutation headers are what the upscaler's shader blob
#           tables are built from, so the tool has to be ported and run here.
#           Every command-line flag v2.3.0's BuildFSR3UpscalerShaders.bat uses
#           exists in the 1.1.4 sources.
#
# Both checkouts are sparse: the full repository is several GB of samples and
# media, of which this build needs about 190 MB.
#
# The port itself lives in Patches/fidelityfx/ (see its README.md) and is
# applied to pristine checkouts on every run, exactly like the vkd3d-proton and
# DXC patch series.
#
# Shader compilation uses a STOCK DXC built from the same pinned tag as
# Scripts/build_dxc.sh, in its own build tree (build/dxc-host). The shipped
# libdxcompiler.so carries the SE2 2-byte-WCHAR ABI patch
# (Patches/dxc/0001-se2-windows-wchar-abi.patch) and is deliberately
# incompatible with a normal 4-byte-wchar_t caller such as this shader
# compiler, so the two cannot share a build. The host build is cached under its
# own stamp and is not shipped.
#
# The generated DXIL is unsigned, like every other shader this port compiles:
# vkd3d-proton does not validate DXIL signatures, which is the same reason
# libdxil.so is deliberately absent from the archive (see docs/dependencies.md).
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── Libraries-SE2/             SE2 staging dir this script populates
#   ├── fidelityfx/                sparse clone at the pinned SDK tag
#   ├── ffx-sc-src/                sparse clone at the pinned ffx_sc tag
#   ├── dxc-host/                  stock (unpatched) DXC for the host tool
#   ├── fidelityfx-compat/         generated <d3d12.h> etc. onto vkd3d-proton
#   ├── fidelityfx-sc/             the built FidelityFX_SC host tool
#   ├── fidelityfx-shaders/        generated shader permutation headers
#   ├── fidelityfx-obj/            object files for the shared library
#   ├── dxc-host.stamp             last-built host DXC commit
#   └── fidelityfx.stamp           last-built commits + patch-series hash
#
# Usage:
#   ./build_fidelityfx.sh           Build (or no-op if cached).
#   ./build_fidelityfx.sh --clean   Wipe build dirs and rebuild from scratch.
#   ./build_fidelityfx.sh --print-stamp
#                                   Print this build's cache stamp and exit
#                                   without touching the network. The value is
#                                   the content key CI caches the staged
#                                   library under; see docs/building.md.
#
# Env-var overrides (defaults shown):
#   FIDELITYFX_TAG      = v2.3.0
#   FIDELITYFX_COMMIT   = 60f4ea81909200d8542eca14dccb2628b763a9a3
#   FFX_SC_TAG          = v1.1.4
#   FFX_SC_COMMIT       = c6efa6bf7f2027b3ec94f28578bb5965eabb9e55
#   FIDELITYFX_REPO     = https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK.git
#   BUILD_DIR           = <repo>/build
#   LIBRARIES_SE2_DIR   = $BUILD_DIR/Libraries-SE2
#   JOBS                = $(nproc)
#
# Requirements: git, cmake (>=3.20), ninja, python3, gcc, g++ (C++20),
# patchelf. The host DXC build is the expensive part -- the same tens of
# minutes as Scripts/build_dxc.sh -- and everything after it takes seconds.
#
# Runs after build_vkd3d_proton.sh: the DX12 backend is compiled against
# vkd3d-proton's installed headers, which that script produces, and this one
# invokes it if they are not there yet.

set -euo pipefail

FIDELITYFX_TAG="${FIDELITYFX_TAG:-v2.3.0}"
FIDELITYFX_COMMIT="${FIDELITYFX_COMMIT:-60f4ea81909200d8542eca14dccb2628b763a9a3}"
FFX_SC_TAG="${FFX_SC_TAG:-v1.1.4}"
FFX_SC_COMMIT="${FFX_SC_COMMIT:-c6efa6bf7f2027b3ec94f28578bb5965eabb9e55}"
FIDELITYFX_REPO="${FIDELITYFX_REPO:-https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK.git}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR_DEFAULT="$REPO_DIR/build"

BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"
LIBRARIES_SE2_DIR="${LIBRARIES_SE2_DIR:-$BUILD_DIR/Libraries-SE2}"
JOBS="${JOBS:-$(nproc)}"

PATCHES_DIR="$REPO_DIR/Patches/fidelityfx"

SDK_DIR="$BUILD_DIR/fidelityfx"
SC_SRC_DIR="$BUILD_DIR/ffx-sc-src"
DXC_HOST_DIR="$BUILD_DIR/dxc-host"
COMPAT_DIR="$BUILD_DIR/fidelityfx-compat"
SC_BIN_DIR="$BUILD_DIR/fidelityfx-sc"
SHADER_DIR="$BUILD_DIR/fidelityfx-shaders"
OBJ_DIR="$BUILD_DIR/fidelityfx-obj"
STAMP_FILE="$BUILD_DIR/fidelityfx.stamp"
DXC_HOST_STAMP_FILE="$BUILD_DIR/dxc-host.stamp"

KIT_DIR="$SDK_DIR/Kits/FidelityFX"

EXPECTED_LIBS=(libamd_fidelityfx_loader_dx12.so)

# The sparse-checkout cone for the SDK. amdinternal/ does not exist upstream;
# it is where Patches/fidelityfx/sdk/0001 puts the two stub headers that stand
# in for AMD's closed tree, and it has to be inside the cone to be writable.
SDK_SPARSE_PATHS=(
    Kits/FidelityFX/api
    Kits/FidelityFX/backend/dx12
    Kits/FidelityFX/upscalers
    Kits/FidelityFX/framegeneration
    Kits/FidelityFX/amdinternal
)

CLEAN=0
PRINT_STAMP=0
for arg in "$@"; do
    case "$arg" in
        --clean)       CLEAN=1 ;;
        --print-stamp) PRINT_STAMP=1 ;;
        -h|--help) sed -n '2,96p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# The DXC pin is read out of build_dxc.sh rather than duplicated here: the host
# tool must be the same compiler version as the shipped one, minus the SE2 ABI
# patch, and a second copy of the pin would drift the first time DXC is bumped.
DXC_TAG="$(sed -n 's/^DXC_TAG="${DXC_TAG:-\(.*\)}"$/\1/p' "$SCRIPT_DIR/build_dxc.sh")"
DXC_COMMIT="$(sed -n 's/^DXC_COMMIT="${DXC_COMMIT:-\(.*\)}"$/\1/p' "$SCRIPT_DIR/build_dxc.sh")"
DXC_REPO="$(sed -n 's/^DXC_REPO="${DXC_REPO:-\(.*\)}"$/\1/p' "$SCRIPT_DIR/build_dxc.sh")"
if [ -z "$DXC_TAG" ] || [ -z "$DXC_COMMIT" ] || [ -z "$DXC_REPO" ]; then
    echo "ERROR: could not read the DXC pin out of $SCRIPT_DIR/build_dxc.sh." >&2
    echo "       The DXC_TAG/DXC_COMMIT/DXC_REPO lines there changed shape." >&2
    exit 1
fi

# The patch series is part of the cache key: adding, editing or removing a
# patch must invalidate the cached build. LC_ALL=C pins the sort order so the
# hash does not depend on the host locale.
PATCH_FILES=()
if [ -d "$PATCHES_DIR" ]; then
    while IFS= read -r p; do
        PATCH_FILES+=("$p")
    done < <(find "$PATCHES_DIR" -mindepth 2 -maxdepth 2 -name '*.patch' | LC_ALL=C sort)
fi

if [ "${#PATCH_FILES[@]}" -gt 0 ]; then
    PATCH_HASH="$(cat "${PATCH_FILES[@]}" | sha256sum | cut -d' ' -f1)"
else
    PATCH_HASH="no-patches"
fi
STAMP_CONTENT="$FIDELITYFX_COMMIT sc=$FFX_SC_COMMIT dxc=$DXC_COMMIT patches=$PATCH_HASH"

if [ "$PRINT_STAMP" = "1" ]; then
    printf '%s\n' "$STAMP_CONTENT"
    exit 0
fi

# ---- preflight --------------------------------------------------------------

for tool in git cmake ninja python3 gcc g++ patchelf; do
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
    rm -rf "$SDK_DIR" "$SC_SRC_DIR" "$COMPAT_DIR" "$SC_BIN_DIR" "$SHADER_DIR" "$OBJ_DIR"
elif [ "$ALL_LIBS_PRESENT" = "1" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
    echo "==> Cached build matches FidelityFX SDK $FIDELITYFX_TAG; skipping rebuild"
    echo "==> FidelityFX lib already in $LIBRARIES_SE2_DIR:"
    ( cd "$LIBRARIES_SE2_DIR" && ls -1 libamd_fidelityfx_loader_dx12.so )
    exit 0
fi

# ---- vkd3d-proton headers ---------------------------------------------------
# The DX12 backend is compiled against vkd3d-proton's own D3D12 headers, so its
# ID3D12Device/ID3D12Resource vtables are by construction the ones the game
# passes in. Mirrors how build_dxvk.sh ensures SDL3 is present.

VKD3D_INCLUDE_DIR="$BUILD_DIR/vkd3d-proton-out/include/vkd3d-proton"
if [ ! -f "$VKD3D_INCLUDE_DIR/vkd3d_d3d12.h" ]; then
    echo "==> Ensuring vkd3d-proton headers are available for the FidelityFX build"
    bash "$SCRIPT_DIR/build_vkd3d_proton.sh"
fi
if [ ! -f "$VKD3D_INCLUDE_DIR/vkd3d_d3d12.h" ]; then
    echo "ERROR: vkd3d-proton headers not found at $VKD3D_INCLUDE_DIR." >&2
    echo "       Run Scripts/build_vkd3d_proton.sh first." >&2
    exit 1
fi

# ---- clone (cached) ---------------------------------------------------------
# Sparse cones keep both checkouts to the directories this build reads. As in
# build_dxc.sh, the pinned SHA is asserted against what the tag resolves to, so
# a moved tag fails the build instead of silently building something else.

sparse_clone() {
    # sparse_clone <dir> <tag> <commit> <sparse path>...
    local dir="$1" tag="$2" commit="$3"; shift 3

    if [ ! -d "$dir/.git" ]; then
        echo "==> Fetching $FIDELITYFX_REPO @ $tag -> $dir"
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" remote add origin "$FIDELITYFX_REPO"
        git -C "$dir" config core.sparseCheckout true
        git -C "$dir" sparse-checkout init --cone
    fi
    git -C "$dir" sparse-checkout set "$@"
    if ! git -C "$dir" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null; then
        git -C "$dir" fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    fi
    git -C "$dir" -c advice.detachedHead=false checkout "refs/tags/$tag"

    local actual
    actual="$(git -C "$dir" rev-parse HEAD)"
    if [ "$actual" != "$commit" ]; then
        echo "ERROR: tag $tag resolves to $actual," >&2
        echo "       but the pin in this script is $commit." >&2
        echo "       The upstream tag was moved; see docs/maintenance.md." >&2
        exit 1
    fi

    # A hard reset rather than `git checkout -- .`: the patch series adds files,
    # and a previous run's additions have to leave both the working tree and
    # the index before the series is applied again.
    echo "==> Resetting $(basename "$dir") to pristine $tag (${commit:0:12})"
    git -C "$dir" reset -q --hard "refs/tags/$tag"
    git -C "$dir" clean -fdx --quiet
}

sparse_clone "$SDK_DIR" "$FIDELITYFX_TAG" "$FIDELITYFX_COMMIT" "${SDK_SPARSE_PATHS[@]}"
sparse_clone "$SC_SRC_DIR" "$FFX_SC_TAG" "$FFX_SC_COMMIT" sdk/tools/ffx_shader_compiler

# ---- apply the patch series -------------------------------------------------
# Patches/fidelityfx/sdk/ applies to the v2.3.0 checkout and
# Patches/fidelityfx/ffx-sc/ to the v1.1.4 one.

if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
    echo "==> No patches under $PATCHES_DIR; building pristine upstream"
fi
for p in ${PATCH_FILES[@]+"${PATCH_FILES[@]}"}; do
    case "$(basename "$(dirname "$p")")" in
        sdk)    target="$SDK_DIR" ;;
        ffx-sc) target="$SC_SRC_DIR" ;;
        *)  echo "ERROR: patch in an unknown subdirectory: $p" >&2
            echo "       Expected Patches/fidelityfx/{sdk,ffx-sc}/*.patch." >&2
            exit 1 ;;
    esac
    echo "==> Applying $(basename "$(dirname "$p")")/$(basename "$p")"
    if ! git -C "$target" apply "$p"; then
        echo "ERROR: patch failed to apply: $p" >&2
        echo "       The series under Patches/fidelityfx/ needs a rebase." >&2
        echo "       See docs/maintenance.md." >&2
        exit 1
    fi
done

# ---- host DXC (stock, unpatched) --------------------------------------------
# Same pin as the shipped compiler, without Patches/dxc/. Cached separately
# from the FidelityFX stamp so an edit to the FidelityFX patch series does not
# cost another full DXC build.

DXC_HOST_LIB="$DXC_HOST_DIR/build/lib/libdxcompiler.so"
if [ -f "$DXC_HOST_LIB" ] \
   && [ -f "$DXC_HOST_STAMP_FILE" ] \
   && [ "$(cat "$DXC_HOST_STAMP_FILE")" = "$DXC_COMMIT" ]; then
    echo "==> Cached host DXC matches $DXC_TAG (${DXC_COMMIT:0:12}); skipping rebuild"
else
    if [ ! -d "$DXC_HOST_DIR/.git" ]; then
        echo "==> Fetching $DXC_REPO @ $DXC_TAG -> $DXC_HOST_DIR"
        rm -rf "$DXC_HOST_DIR"
        git init -q "$DXC_HOST_DIR"
        git -C "$DXC_HOST_DIR" remote add origin "$DXC_REPO"
    fi
    if ! git -C "$DXC_HOST_DIR" rev-parse -q --verify "refs/tags/$DXC_TAG^{commit}" >/dev/null; then
        git -C "$DXC_HOST_DIR" fetch --depth 1 origin "refs/tags/$DXC_TAG:refs/tags/$DXC_TAG"
    fi
    git -C "$DXC_HOST_DIR" -c advice.detachedHead=false checkout "refs/tags/$DXC_TAG"

    DXC_HOST_ACTUAL="$(git -C "$DXC_HOST_DIR" rev-parse HEAD)"
    if [ "$DXC_HOST_ACTUAL" != "$DXC_COMMIT" ]; then
        echo "ERROR: tag $DXC_TAG resolves to $DXC_HOST_ACTUAL," >&2
        echo "       but the pin in build_dxc.sh is $DXC_COMMIT." >&2
        exit 1
    fi

    echo "==> Resetting host DXC to pristine $DXC_TAG (no Patches/dxc/ here)"
    git -C "$DXC_HOST_DIR" checkout -- .
    git -C "$DXC_HOST_DIR" clean -fdxe build --quiet

    for module in external/DirectX-Headers external/SPIRV-Headers external/SPIRV-Tools; do
        git -C "$DXC_HOST_DIR" submodule update --init --depth 1 "$module"
    done

    echo "==> Configuring host DXC (release, no tests)"
    cmake -S "$DXC_HOST_DIR" -B "$DXC_HOST_DIR/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DSPIRV_BUILD_TESTS=OFF \
        -DHLSL_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_TESTS=OFF \
        -C "$DXC_HOST_DIR/cmake/caches/PredefinedParams.cmake"

    echo "==> Building host DXC (tens of minutes; ~19 on 4 cores)"
    ninja -C "$DXC_HOST_DIR/build" -j "$JOBS" dxcompiler

    [ -f "$DXC_HOST_LIB" ] || {
        echo "ERROR: the host DXC build did not produce $DXC_HOST_LIB" >&2
        exit 1
    }
    printf '%s\n' "$DXC_COMMIT" > "$DXC_HOST_STAMP_FILE"
fi

DXC_INCLUDE_ARGS=(
    -I "$DXC_HOST_DIR/include"
    -I "$DXC_HOST_DIR/external/DirectX-Headers/include/directx"
    -I "$DXC_HOST_DIR/external/DirectX-Headers/include/wsl/stubs"
)

# ---- build FidelityFX_SC (host tool) ----------------------------------------
# Four translation units: the GLSL/glslangValidator backend, the FXC backend
# and the Agility SDK the upstream CMake project also builds are all dropped by
# the patch series, and with them tiny-process-library and SPIRV-Reflect.

echo "==> Building the FidelityFX_SC shader compiler (host tool)"
rm -rf "$SC_BIN_DIR"
mkdir -p "$SC_BIN_DIR"
SC_SRC="$SC_SRC_DIR/sdk/tools/ffx_shader_compiler/src"
g++ -std=c++17 -O2 -o "$SC_BIN_DIR/ffx_sc" \
    "$SC_SRC/ffx_sc.cpp" "$SC_SRC/hlsl_compiler.cpp" "$SC_SRC/utils.cpp" \
    "${DXC_INCLUDE_ARGS[@]}" \
    -ldl -lpthread

# ---- generate the shader permutation headers --------------------------------
# A shell transcription of Kits/FidelityFX/upscalers/fsr3/dx12/
# BuildFSR3UpscalerShaders.bat: every pass is compiled in four variants
# (wave32/wave64 x fp32/fp16), each one expanding six boolean shader options
# into 64 permutations. Duplicate permutations are collapsed by the compiler.

echo "==> Generating FSR 3.1 shader permutation headers"
rm -rf "$SHADER_DIR"
mkdir -p "$SHADER_DIR"

export LD_LIBRARY_PATH="$DXC_HOST_DIR/build/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

FFX_INCLUDE_ARGS=(-I "$KIT_DIR/api/internal/gpu" -I "$KIT_DIR/upscalers/fsr3/include/gpu")
FFX_API_BASE_ARGS=(-embed-arguments -E CS -Wno-for-redefinition -Wno-ambig-lit-shift -DFFX_HLSL=1)
FFX_BASE_ARGS=(-reflection -deps=gcc -DFFX_GPU=1 -DFFX_IMPLICIT_SHADER_REGISTER_BINDING_HLSL=0)
HLSL_WAVE32_ARGS=(-DFFX_HLSL_SM=62 -T cs_6_2)
HLSL_WAVE64_ARGS=(-DFFX_PREFER_WAVE64="[WaveSize(64)]" -DFFX_HLSL_SM=66 -T cs_6_6)
HLSL_16BIT_ARGS=(-DFFX_HALF=1 -enable-16bit-types)

FSR3_API_BASE_ARGS=("${FFX_API_BASE_ARGS[@]}" -DFFX_FSR3UPSCALER_EMBED_ROOTSIG=0)
FSR3_BASE_ARGS=(
    -DFFX_FSR3UPSCALER_OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0
    -DFFX_FSR3UPSCALER_OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0
    -DFFX_FSR3UPSCALER_OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1
    -DFFX_FSR3UPSCALER_OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0
    -DFFX_FSR3UPSCALER_OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2
    "${FFX_BASE_ARGS[@]}"
)
FSR3_PERMUTATION_ARGS=(
    "-DFFX_FSR3UPSCALER_OPTION_REPROJECT_USE_LANCZOS_TYPE={0,1}"
    "-DFFX_FSR3UPSCALER_OPTION_HDR_COLOR_INPUT={0,1}"
    "-DFFX_FSR3UPSCALER_OPTION_LOW_RESOLUTION_MOTION_VECTORS={0,1}"
    "-DFFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS={0,1}"
    "-DFFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH={0,1}"
    "-DFFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING={0,1}"
)
FSR3_SC_ARGS=("${FSR3_BASE_ARGS[@]}" "${FSR3_API_BASE_ARGS[@]}" "${FSR3_PERMUTATION_ARGS[@]}")

SHADER_COUNT=0
for hlsl in "$KIT_DIR"/upscalers/fsr3/internal/shaders/ffx_fsr3upscaler_*.hlsl; do
    name="$(basename "$hlsl" .hlsl)"
    "$SC_BIN_DIR/ffx_sc" -Zs "${FSR3_SC_ARGS[@]}" -name="$name" \
        -DFFX_HALF=0 "${HLSL_WAVE32_ARGS[@]}" \
        "${FFX_INCLUDE_ARGS[@]}" -output="$SHADER_DIR" "$hlsl" > /dev/null
    "$SC_BIN_DIR/ffx_sc" -Zs "${FSR3_SC_ARGS[@]}" -name="${name}_wave64" \
        -DFFX_HALF=0 "${HLSL_WAVE64_ARGS[@]}" \
        "${FFX_INCLUDE_ARGS[@]}" -output="$SHADER_DIR" "$hlsl" > /dev/null
    "$SC_BIN_DIR/ffx_sc" -Zs "${FSR3_SC_ARGS[@]}" -name="${name}_16bit" \
        "${HLSL_16BIT_ARGS[@]}" "${HLSL_WAVE32_ARGS[@]}" \
        "${FFX_INCLUDE_ARGS[@]}" -output="$SHADER_DIR" "$hlsl" > /dev/null
    "$SC_BIN_DIR/ffx_sc" -Zs "${FSR3_SC_ARGS[@]}" -name="${name}_wave64_16bit" \
        "${HLSL_16BIT_ARGS[@]}" "${HLSL_WAVE64_ARGS[@]}" \
        "${FFX_INCLUDE_ARGS[@]}" -output="$SHADER_DIR" "$hlsl" > /dev/null
    SHADER_COUNT=$((SHADER_COUNT + 1))
    echo "  $name"
done

if [ "$SHADER_COUNT" = "0" ]; then
    echo "ERROR: no FSR 3 upscaler shaders found under" >&2
    echo "       $KIT_DIR/upscalers/fsr3/internal/shaders/" >&2
    exit 1
fi

# ---- generate the D3D12 compatibility headers -------------------------------
# The SDK includes <d3d12.h>, <dxgi.h> and friends by their Windows names.
# vkd3d-proton installs the same interfaces under vkd3d_-prefixed names, so a
# handful of forwarding headers is all that stands between them. NOMINMAX keeps
# vkd3d_windows.h from defining min()/max() as function macros, which collide
# with std::numeric_limits<T>::max() inside both libstdc++ and the SDK.

echo "==> Generating the D3D12 compatibility headers"
rm -rf "$COMPAT_DIR"
mkdir -p "$COMPAT_DIR/include"

cat > "$COMPAT_DIR/include/windows.h" <<'EOF'
#pragma once
#define NOMINMAX
#include <vkd3d_windows.h>

// vkd3d-proton provides __uuidof emulation but not the IID_PPV_ARGS
// convenience macro the FidelityFX SDK uses at every CreateXxx call site.
#ifndef IID_PPV_ARGS
extern "C++"
{
    template <typename T>
    inline void** IID_PPV_ARGS_Helper(T** pp)
    {
        return reinterpret_cast<void**>(pp);
    }
}
#define IID_PPV_ARGS(ppType) __uuidof(**(ppType)), IID_PPV_ARGS_Helper(ppType)
#endif
EOF

cat > "$COMPAT_DIR/include/d3d12.h" <<'EOF'
#pragma once
#include "windows.h"
#include <vkd3d_d3d12.h>
EOF

cat > "$COMPAT_DIR/include/d3dcommon.h" <<'EOF'
#pragma once
#include "windows.h"
#include <vkd3d_d3dcommon.h>
EOF

cat > "$COMPAT_DIR/include/dxgiformat.h" <<'EOF'
#pragma once
#include "windows.h"
#include <vkd3d_dxgiformat.h>
EOF

for header in dxgi.h dxgi1_5.h; do
    cat > "$COMPAT_DIR/include/$header" <<'EOF'
#pragma once
#include "windows.h"
#include <vkd3d_dxgi1_5.h>
EOF
done

cat > "$COMPAT_DIR/include/dxgi1_6.h" <<'EOF'
#pragma once
// vkd3d-proton stops at IDXGISwapChain3 (dxgi1_4). IDXGISwapChain4 appears
// only in the SDK's frame generation entry points, which this build does not
// compile, and only ever as a pointer -- an incomplete type keeps those
// declarations valid without pulling in a swap chain implementation.
#include "windows.h"
#include <vkd3d_dxgi1_5.h>

struct IDXGISwapChain4;
EOF

# ---- compile the shared library ---------------------------------------------
# FFX_UPSCALER selects the upscaler entry points in the shared api/backend
# sources; frame generation, the denoiser and the radiance cache are not built.
# FFX_BACKEND_DX12 stays undefined on purpose: it does not select the DX12
# backend (compiling backend/dx12 does that) but the driver-side "external"
# provider, which lives in AMD's closed amdinternal tree. FFX_GCC switches the
# SDK's internal FFX_API annotation off; only the five ffx_api entry points
# carry default visibility.

echo "==> Compiling libamd_fidelityfx_loader_dx12.so"
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"

FFX_SOURCES=(
    "$KIT_DIR/api/internal/ffx_api.cpp"
    "$KIT_DIR/api/internal/ffx_assert.cpp"
    "$KIT_DIR/api/internal/ffx_message.cpp"
    "$KIT_DIR/api/internal/ffx_object_management.cpp"
    "$KIT_DIR/api/internal/ffx_query_fallback.cpp"
    "$KIT_DIR/api/internal/ffx_providers_linux.cpp"
    "$KIT_DIR/backend/dx12/ffx_dx12.cpp"
    "$KIT_DIR/backend/dx12/ffx_backends_dx12.cpp"
    "$KIT_DIR/upscalers/fsr3/internal/ffx_fsr3upscaler.cpp"
    "$KIT_DIR/upscalers/fsr3/internal/ffx_fsr3upscaler_shaderblobs.cpp"
    "$KIT_DIR/upscalers/fsr3/internal/ffx_provider_fsr3upscale.cpp"
)

FFX_COMPILE_ARGS=(
    -std=gnu++20 -O2 -fPIC -fvisibility=hidden
    -DFFX_UPSCALER=1 -DFFX_GCC=1
    -include "$KIT_DIR/api/internal/ffx_linux_compat.h"
    -I "$COMPAT_DIR/include"
    -I "$VKD3D_INCLUDE_DIR"
    -I "$SHADER_DIR"
)

# Eleven translation units, the largest of which pulls in 22 MB of generated
# shader blobs, so this is well under a minute even on one core.
for src in "${FFX_SOURCES[@]}"; do
    echo "  $(basename "$src")"
    g++ "${FFX_COMPILE_ARGS[@]}" -c "$src" -o "$OBJ_DIR/$(basename "$src" .cpp).o"
done

# --no-undefined turns a missing symbol into a link error here rather than a
# dlopen failure inside the game.
g++ -shared -o "$OBJ_DIR/libamd_fidelityfx_loader_dx12.so" "$OBJ_DIR"/*.o \
    -Wl,--no-undefined -ldl

# ---- verify the exported surface --------------------------------------------
# The game P/Invokes exactly these five symbols. Anything missing here is a
# DllNotFoundException-grade failure on the render thread.

echo "==> Verifying the exported entry points"
for symbol in ffxCreateContext ffxDestroyContext ffxConfigure ffxQuery ffxDispatch; do
    if ! nm -D --defined-only "$OBJ_DIR/libamd_fidelityfx_loader_dx12.so" \
        | grep -q " T $symbol\$"; then
        echo "ERROR: $symbol is not exported by the built library." >&2
        exit 1
    fi
done

# ---- stage ------------------------------------------------------------------

echo "==> Staging FidelityFX into $LIBRARIES_SE2_DIR"
install -m 0755 "$OBJ_DIR/libamd_fidelityfx_loader_dx12.so" \
    "$LIBRARIES_SE2_DIR/libamd_fidelityfx_loader_dx12.so"

# ---- patch DT_RUNPATH=$ORIGIN -----------------------------------------------
# Parity with the vkd3d-proton and DXVK payloads. This library has no NEEDED
# entry on its siblings, but it dlopens libvkd3d-proton-d3d12.so for
# D3D12SerializeRootSignature when the caller did not load it under that name.

echo "==> Patching DT_RUNPATH=\$ORIGIN onto the FidelityFX lib"
patchelf --set-rpath '$ORIGIN' "$LIBRARIES_SE2_DIR/libamd_fidelityfx_loader_dx12.so"

# ---- update cache stamp -----------------------------------------------------

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

echo
echo "==> Staged FidelityFX into $LIBRARIES_SE2_DIR:"
( cd "$LIBRARIES_SE2_DIR" && ls -1 libamd_fidelityfx_loader_dx12.so )
