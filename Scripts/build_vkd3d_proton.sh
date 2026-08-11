#!/usr/bin/env bash
# build_vkd3d_proton.sh
#
# Builds vkd3d-proton (the Proton fork of vkd3d: a Direct3D 12 implementation
# over Vulkan) from upstream sources at
# https://github.com/HansKristian-Work/vkd3d-proton, with the patch series
# under Patches/vkd3d-proton/ applied first, then installs the two native .so
# files the Space Engineers 2 client needs into the build/Libraries staging
# folder:
#
#   libvkd3d-proton-d3d12.so
#   libvkd3d-proton-d3d12core.so
#
# The patches fix bugs the Space Engineers 2 client hits (see
# Patches/vkd3d-proton/README.md); the patched libraries ship in BOTH release
# archives, per the policy that a patched library appears in every archive.
#
# The pin is a commit SHA rather than a tag because the patch series was
# developed and tested against this exact upstream state.
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── Libraries/                 staging dir all dep scripts populate
#   ├── vkd3d-proton/              clone at the pinned commit
#   ├── vkd3d-proton-out/          meson install destdir (recreated)
#   └── vkd3d-proton.stamp         last-built commit + patch-series hash
#
# Usage:
#   ./build_vkd3d_proton.sh           Build (or no-op if cached).
#   ./build_vkd3d_proton.sh --clean   Wipe build dirs and rebuild from scratch.
#
# Env-var overrides (defaults shown):
#   VKD3D_PROTON_COMMIT = 3dfc6f07d0953b1e8b41705275c2c59cc7374fc5
#   VKD3D_PROTON_REPO   = https://github.com/HansKristian-Work/vkd3d-proton.git
#   BUILD_DIR           = <repo>/build
#   LIBRARIES_DIR       = $BUILD_DIR/Libraries
#   JOBS                = $(nproc)
#
# Requirements: git, meson (>=0.58), ninja, glslang (glslangValidator),
# pkg-config, gcc, g++, patchelf, and widl (the Wine IDL compiler, used by
# vkd3d-proton to generate its COM headers). On Debian/Ubuntu widl comes from
# the mingw-w64-tools package (as x86_64-w64-mingw32-widl, which this script
# shims onto PATH under the name meson looks for) or from wine64-tools.

set -euo pipefail

VKD3D_PROTON_COMMIT="${VKD3D_PROTON_COMMIT:-3dfc6f07d0953b1e8b41705275c2c59cc7374fc5}"
VKD3D_PROTON_REPO="${VKD3D_PROTON_REPO:-https://github.com/HansKristian-Work/vkd3d-proton.git}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR_DEFAULT="$REPO_DIR/build"

BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"
LIBRARIES_DIR="${LIBRARIES_DIR:-$BUILD_DIR/Libraries}"
JOBS="${JOBS:-$(nproc)}"

PATCHES_DIR="$REPO_DIR/Patches/vkd3d-proton"

SRC_DIR="$BUILD_DIR/vkd3d-proton"
OUT_DIR="$BUILD_DIR/vkd3d-proton-out"
STAMP_FILE="$BUILD_DIR/vkd3d-proton.stamp"

EXPECTED_LIBS=(libvkd3d-proton-d3d12.so libvkd3d-proton-d3d12core.so)

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean)   CLEAN=1 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# The patch series is part of the cache key: adding, editing or removing a
# patch must invalidate the cached build. LC_ALL=C pins the sort order so the
# hash does not depend on the host locale.
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
STAMP_CONTENT="$VKD3D_PROTON_COMMIT patches=$PATCH_HASH"

# ---- preflight --------------------------------------------------------------

for tool in git meson ninja glslangValidator pkg-config gcc g++ patchelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done

# vkd3d-proton's meson looks for `widl` (or `widl-stable`). Ubuntu's
# mingw-w64-tools ships it as x86_64-w64-mingw32-widl only, so when that is
# the one available, expose it to meson through a shim directory on PATH.
if ! command -v widl >/dev/null 2>&1 && ! command -v widl-stable >/dev/null 2>&1; then
    if command -v x86_64-w64-mingw32-widl >/dev/null 2>&1; then
        WIDL_SHIM_DIR="$BUILD_DIR/widl-shim"
        mkdir -p "$WIDL_SHIM_DIR"
        ln -sfn "$(command -v x86_64-w64-mingw32-widl)" "$WIDL_SHIM_DIR/widl"
        export PATH="$WIDL_SHIM_DIR:$PATH"
    else
        echo "ERROR: widl (Wine IDL compiler) not found in PATH." >&2
        echo "       Install mingw-w64-tools (Debian/Ubuntu) or wine64-tools." >&2
        exit 1
    fi
fi

mkdir -p "$BUILD_DIR" "$LIBRARIES_DIR"

# ---- cache check ------------------------------------------------------------

ALL_LIBS_PRESENT=1
for lib in "${EXPECTED_LIBS[@]}"; do
    [ -e "$LIBRARIES_DIR/$lib" ] || ALL_LIBS_PRESENT=0
done

if [ "$CLEAN" = "1" ]; then
    rm -rf "$SRC_DIR" "$OUT_DIR"
elif [ "$ALL_LIBS_PRESENT" = "1" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
    echo "==> Cached build matches vkd3d-proton ${VKD3D_PROTON_COMMIT:0:12}; skipping rebuild"
    echo "==> vkd3d-proton libs already in $LIBRARIES_DIR:"
    ( cd "$LIBRARIES_DIR" && ls -1 libvkd3d-proton-*.so* )
    exit 0
fi

# ---- clone (cached) ---------------------------------------------------------
# The pin is a bare commit SHA, which a --branch shallow clone cannot fetch.
# GitHub allows fetching arbitrary reachable SHAs, so init + fetch-by-SHA
# gives a depth-1 checkout of exactly the pinned state.

if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> Fetching $VKD3D_PROTON_REPO @ ${VKD3D_PROTON_COMMIT:0:12} -> $SRC_DIR"
    rm -rf "$SRC_DIR"
    git init -q "$SRC_DIR"
    git -C "$SRC_DIR" remote add origin "$VKD3D_PROTON_REPO"
fi
if ! git -C "$SRC_DIR" cat-file -e "$VKD3D_PROTON_COMMIT^{commit}" 2>/dev/null; then
    git -C "$SRC_DIR" fetch --depth 1 origin "$VKD3D_PROTON_COMMIT"
fi
git -C "$SRC_DIR" -c advice.detachedHead=false checkout "$VKD3D_PROTON_COMMIT"
git -C "$SRC_DIR" submodule update --init --recursive --depth 1

# ---- reset to pristine, then apply the patch series -------------------------
# The clone is cached across runs, so the tree is forced back to the pristine
# pinned state before the series is applied — a previous run's applied patches
# (or an edited series) would otherwise stack or conflict.

echo "==> Resetting vkd3d-proton source tree to pristine ${VKD3D_PROTON_COMMIT:0:12}"
git -C "$SRC_DIR" checkout -- .
git -C "$SRC_DIR" clean -fdx --quiet
git -C "$SRC_DIR" submodule foreach --recursive --quiet \
    'git checkout -- . && git clean -fdx --quiet'

if [ "${#PATCH_FILES[@]}" -eq 0 ]; then
    echo "==> No patches under $PATCHES_DIR; building pristine upstream"
fi
for p in ${PATCH_FILES[@]+"${PATCH_FILES[@]}"}; do
    echo "==> Applying $(basename "$p")"
    if ! git -C "$SRC_DIR" apply "$p"; then
        echo "ERROR: patch failed to apply: $p" >&2
        echo "       The series under Patches/vkd3d-proton/ needs a rebase" >&2
        echo "       onto commit $VKD3D_PROTON_COMMIT. See docs/maintenance.md." >&2
        exit 1
    fi
done

# ---- build ------------------------------------------------------------------
# A plain native meson build produces the libvkd3d-proton-d3d12.so and
# libvkd3d-proton-d3d12core.so shared libraries. The install step is used so
# the outputs land in a predictable destdir, mirroring the DXVK build.

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> Building vkd3d-proton (native, release)"
(
    cd "$SRC_DIR"
    meson setup build-native \
        --buildtype release \
        --prefix "$OUT_DIR" \
        --libdir lib
    ninja -C build-native -j "$JOBS"
    meson install -C build-native --quiet
)

# ---- locate + stage the .so outputs -----------------------------------------

echo "==> Staging vkd3d-proton libs into $LIBRARIES_DIR"
for lib in "${EXPECTED_LIBS[@]}"; do
    src="$(find -L "$OUT_DIR" -type f -name "$lib" -print -quit)"
    if [ -z "$src" ]; then
        echo "ERROR: the build did not produce $lib under $OUT_DIR" >&2
        exit 1
    fi
    install -m 0755 "$src" "$LIBRARIES_DIR/$lib"
done

# ---- patch DT_RUNPATH=$ORIGIN onto each .so ---------------------------------
# Parity with the FFmpeg and DXVK payloads: ld.so resolves any sibling NEEDED
# entries (d3d12 -> d3d12core) via the loaded lib's own directory, so the
# consumer's launcher doesn't need to manipulate LD_LIBRARY_PATH.

echo "==> Patching DT_RUNPATH=\$ORIGIN onto vkd3d-proton libs"
for lib in "${EXPECTED_LIBS[@]}"; do
    patchelf --set-rpath '$ORIGIN' "$LIBRARIES_DIR/$lib"
done

# ---- update cache stamp -----------------------------------------------------

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

echo
echo "==> Staged vkd3d-proton libs into $LIBRARIES_DIR:"
( cd "$LIBRARIES_DIR" && ls -1 libvkd3d-proton-*.so* )
