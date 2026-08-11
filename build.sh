#!/usr/bin/env bash
# build.sh
#
# Top-level orchestrator for the Space Engineers Linux binary dependencies.
# Builds every library from source ONCE, stages the results in
# build/Libraries/ (Space Engineers 1) and build/Libraries-SE2/ (Space
# Engineers 2), verifies both staged trees, and packages them as two release
# archives:
#
#   dist/linux-dependencies.tar.gz       SE1 (Pulsar for Linux, Magnetar)
#   dist/linux-dependencies-se2.tar.gz   SE2 (Space Engineers 2 Linux port)
#
# DXVK and vkd3d-proton are built with their patch series applied (see
# Patches/) and the SAME binaries ship in both archives — a patched library
# appears in every archive, and nothing is built twice. FMOD and the SE2
# native wrappers ship only in the SE2 archive, because SE1 does not use them.
#
# Pipeline (in order):
#
#   1. Scripts/build_ffmpeg.sh          FFmpeg 8.1 (libav*.so* / libsw*.so*)
#   2. Scripts/build_dxvk.sh            DXVK Native v2.7.1 + Patches/dxvk/
#                                       (libdxvk_d3d11.so + libdxvk_dxgi.so + .0 links)
#   3. Scripts/build_vkd3d_proton.sh    vkd3d-proton (pinned commit) +
#                                       Patches/vkd3d-proton/
#                                       (libvkd3d-proton-d3d12.so + -d3d12core.so)
#   4. Scripts/build_openal.sh          OpenAL Soft 1.25.2 (libopenal.so*)
#   5. Scripts/build_steamworks_net.sh  Steamworks.NET.dll
#   6. Shared-artefact copy:            the patched DXVK + vkd3d-proton files
#                                       from Libraries/ into Libraries-SE2/
#   7. Vendor copy:                     libEOSSDK-Linux-Shipping.so + libsteam_api.so
#                                       (proprietary, committed under Vendor/)
#   8. SE2 vendor copy:                 the FMOD runtime (libfmod.so.14 +
#                                       libfmodstudio.so.14) from Vendor/
#   9. License copy:                    Licenses/*.txt -> LICENSES/ (SE1);
#                                       DXVK + vkd3d + Licenses/se2/*.txt
#                                       -> LICENSES/ (SE2)
#  10. Final assertion:                 every expected artefact is present
#  11. Package:                         both archives under dist/
#
# The native wrapper libraries (libD3DCompiler.so, libHavok.so,
# libRecastDetour.so, libVRageNative.so) are deliberately NOT part of this
# archive. They are built and released by CometWorks/linux-native-wrappers,
# and consumers fetch that release separately so a wrapper update does not
# require rebuilding this repo.
#
# Usage:
#   ./build.sh                      Build everything and package the archive.
#   ./build.sh --clean              Pass --clean to every sub-build first.
#   ./build.sh --no-package         Stage build/Libraries/ but skip the tarball.
#   ./build.sh --only=ffmpeg,dxvk   Only run the listed sub-builds.
#                                   Vendor + license copies always run.
#   ./build.sh --skip=dxvk          Run every sub-build except the listed ones.
#
# With --only/--skip the staging tree is incomplete by definition, so the
# final assertion is reported but not fatal and packaging is skipped.
#
# Env-var overrides (defaults shown):
#   REPO_DIR          = <dir of this script>
#   BUILD_DIR         = $REPO_DIR/build
#   LIBRARIES_DIR     = $BUILD_DIR/Libraries
#   LIBRARIES_SE2_DIR = $BUILD_DIR/Libraries-SE2
#   OUTPUT_DIR        = $REPO_DIR/dist
#   VENDOR_DIR        = $REPO_DIR/Vendor
#   LICENSES_SRC      = $REPO_DIR/Licenses
#   JOBS              = $(nproc)
#
# Requirements: see docs/building.md. In short: gcc, g++, make, meson, ninja,
# glslangValidator, pkg-config, curl, tar, git, nasm (or yasm), patchelf,
# readelf, and the .NET SDK.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/Scripts"

REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"
LIBRARIES_DIR="${LIBRARIES_DIR:-$BUILD_DIR/Libraries}"
LIBRARIES_SE2_DIR="${LIBRARIES_SE2_DIR:-$BUILD_DIR/Libraries-SE2}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_DIR/dist}"
VENDOR_DIR="${VENDOR_DIR:-$REPO_DIR/Vendor}"
LICENSES_SRC="${LICENSES_SRC:-$REPO_DIR/Licenses}"

ARCHIVE_NAME="linux-dependencies.tar.gz"
ARCHIVE_NAME_SE2="linux-dependencies-se2.tar.gz"

export REPO_DIR BUILD_DIR LIBRARIES_DIR LIBRARIES_SE2_DIR

# ---- arg parsing ------------------------------------------------------------

CLEAN_ARGS=()
ONLY=""
SKIP=""
DO_PACKAGE=1

for arg in "$@"; do
    case "$arg" in
        --clean)      CLEAN_ARGS+=("--clean") ;;
        --no-package) DO_PACKAGE=0 ;;
        --only=*)     ONLY="${arg#--only=}" ;;
        --skip=*)     SKIP="${arg#--skip=}" ;;
        -h|--help)    sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

FILTERED=0
if [ -n "$ONLY" ] || [ -n "$SKIP" ]; then
    FILTERED=1
fi

# Reject unknown step names. Without this a typo (--only=steamworks_net with an
# underscore) matches nothing, silently skips every build, and reports only
# that staging is incomplete.
STEP_NAMES="ffmpeg dxvk vkd3d-proton openal steamworks-net"
for spec in "$ONLY" "$SKIP"; do
    [ -n "$spec" ] || continue
    IFS=',' read -ra names <<< "$spec"
    for name in "${names[@]}"; do
        case " $STEP_NAMES " in
            *" $name "*) ;;
            *) echo "ERROR: unknown step name: $name" >&2
               echo "       Valid names: $STEP_NAMES" >&2
               exit 2 ;;
        esac
    done
done

want_step() {
    # want_step <name> -> 0 if the step should run, 1 otherwise.
    local name="$1"
    if [ -n "$ONLY" ]; then
        case ",$ONLY," in
            *,"$name",*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    if [ -n "$SKIP" ]; then
        case ",$SKIP," in
            *,"$name",*) return 1 ;;
        esac
    fi
    return 0
}

# ---- preflight --------------------------------------------------------------

mkdir -p "$LIBRARIES_DIR/LICENSES" "$LIBRARIES_SE2_DIR/LICENSES"

[ -d "$VENDOR_DIR" ] || {
    echo "ERROR: $VENDOR_DIR not found." >&2
    echo "       Vendor/ holds the committed proprietary SDK blobs" >&2
    echo "       (libEOSSDK-Linux-Shipping.so + libsteam_api.so)." >&2
    exit 1
}

[ -d "$LICENSES_SRC" ] || {
    echo "ERROR: $LICENSES_SRC not found." >&2
    echo "       Licenses/ holds the committed third-party license texts." >&2
    exit 1
}

echo "==> Repo dir        : $REPO_DIR"
echo "==> Build dir       : $BUILD_DIR"
echo "==> Staging dir     : $LIBRARIES_DIR"
echo "==> SE2 staging dir : $LIBRARIES_SE2_DIR"
echo "==> Output dir      : $OUTPUT_DIR"

# ---- 1..5. per-dependency build scripts ------------------------------------

run_step() {
    local name="$1"; shift
    local script="$1"; shift
    if ! want_step "$name"; then
        echo
        echo "==> SKIP $name (filtered)"
        return 0
    fi
    echo
    echo "############################################################"
    echo "# build: $name"
    echo "############################################################"
    bash "$script" "${CLEAN_ARGS[@]+"${CLEAN_ARGS[@]}"}" "$@"
}

run_step ffmpeg         "$SCRIPTS_DIR/build_ffmpeg.sh"
run_step dxvk           "$SCRIPTS_DIR/build_dxvk.sh"
run_step vkd3d-proton   "$SCRIPTS_DIR/build_vkd3d_proton.sh"
run_step openal         "$SCRIPTS_DIR/build_openal.sh"
run_step steamworks-net "$SCRIPTS_DIR/build_steamworks_net.sh"

# ---- 6. shared artefacts: patched libs -> Libraries-SE2/ --------------------
# The patched DXVK and vkd3d-proton libraries ship in BOTH archives but are
# built only once, into Libraries/. Copy them (preserving the SONAME alias
# symlinks) into the SE2 staging tree. Skipped file-by-file under --only /
# --skip filters, when the source files were not staged this run.

echo
echo "############################################################"
echo "# build: shared artefacts (Libraries/ -> Libraries-SE2/)"
echo "############################################################"
SHARED_FILES=(
    libdxvk_d3d11.so libdxvk_d3d11.so.0
    libdxvk_dxgi.so  libdxvk_dxgi.so.0
    libvkd3d-proton-d3d12.so libvkd3d-proton-d3d12core.so
)
for f in "${SHARED_FILES[@]}"; do
    if [ -e "$LIBRARIES_DIR/$f" ]; then
        cp -P "$LIBRARIES_DIR/$f" "$LIBRARIES_SE2_DIR/$f"
        echo "  copied $f"
    elif [ "$FILTERED" = "1" ]; then
        echo "  skipped $f (not staged under the active --only/--skip filter)"
    else
        echo "ERROR: expected shared artefact missing: $LIBRARIES_DIR/$f" >&2
        exit 1
    fi
done

# ---- 7. Vendor blobs --------------------------------------------------------

echo
echo "############################################################"
echo "# build: vendor blobs (Vendor/ -> Libraries/)"
echo "############################################################"
for blob in libEOSSDK-Linux-Shipping.so libsteam_api.so; do
    src="$VENDOR_DIR/$blob"
    if [ ! -f "$src" ]; then
        echo "ERROR: missing vendor blob: $src" >&2
        echo "       These SDKs are proprietary and must stay committed under Vendor/." >&2
        exit 1
    fi
    install -m 0755 "$src" "$LIBRARIES_DIR/$blob"
    echo "  copied $blob"
done

# ---- 8. SE2 vendor blobs (FMOD) ---------------------------------------------
# The proprietary FMOD Engine runtime (login-gated download, committed under
# Vendor/ like EOS and Steamworks). SE1 does not use FMOD, so it ships only
# in the SE2 archive. The file names already carry the SONAMEs, so plain
# copies suffice. The SE2 native wrappers are NOT here: like the SE1
# wrappers, they are built and released by CometWorks/linux-native-wrappers
# and consumers fetch them separately.

echo
echo "############################################################"
echo "# build: SE2 vendor blobs (Vendor/ -> Libraries-SE2/)"
echo "############################################################"
for blob in libfmod.so.14 libfmodstudio.so.14; do
    src="$VENDOR_DIR/$blob"
    if [ ! -f "$src" ]; then
        echo "ERROR: missing vendor blob: $src" >&2
        echo "       These SDKs are proprietary and must stay committed under Vendor/." >&2
        exit 1
    fi
    install -m 0755 "$src" "$LIBRARIES_SE2_DIR/$blob"
    echo "  copied $blob"
done

# ---- 9. Licenses ------------------------------------------------------------
# SE1 archive: every top-level Licenses/*.txt. SE2 archive: the shared DXVK
# and vkd3d-proton notices plus the SE2-specific ones under Licenses/se2/
# (kept in a subdirectory precisely so the SE1 glob below does not pick
# them up).

echo
echo "############################################################"
echo "# build: licenses (Licenses/ -> Libraries/LICENSES/)"
echo "############################################################"
shopt -s nullglob
for f in "$LICENSES_SRC"/*.txt; do
    install -m 0644 "$f" "$LIBRARIES_DIR/LICENSES/$(basename "$f")"
    echo "  copied $(basename "$f")"
done
for shared in DXVK-LICENSE.txt VKD3D-LGPL-2.1.txt vkd3d-proton-README.txt; do
    install -m 0644 "$LICENSES_SRC/$shared" \
        "$LIBRARIES_SE2_DIR/LICENSES/$shared"
    echo "  copied $shared (SE2)"
done
for f in "$LICENSES_SRC"/se2/*.txt; do
    install -m 0644 "$f" "$LIBRARIES_SE2_DIR/LICENSES/$(basename "$f")"
    echo "  copied $(basename "$f") (SE2)"
done
shopt -u nullglob

# ---- 10. final assertion ----------------------------------------------------
# Confirm every artefact every consumer expects is present. Missing files here
# are far easier to debug than a cryptic failure inside a consumer's build.
#
# Keep these lists in sync with docs/release-archive.md, which is the contract
# the consuming repos (Pulsar for Linux, Magnetar, the SE2 port) rely on.

EXPECTED_FILES=(
    # FFmpeg
    libavcodec.so libavcodec.so.62 libavcodec.so.62.28.100
    libavformat.so libavformat.so.62 libavformat.so.62.12.100
    libavutil.so libavutil.so.60 libavutil.so.60.26.100
    libswresample.so libswresample.so.6 libswresample.so.6.3.100
    libswscale.so libswscale.so.9 libswscale.so.9.5.100
    # DXVK (patched, shared with the SE2 archive)
    libdxvk_d3d11.so libdxvk_d3d11.so.0
    libdxvk_dxgi.so  libdxvk_dxgi.so.0
    # vkd3d-proton (patched, shared with the SE2 archive)
    libvkd3d-proton-d3d12.so libvkd3d-proton-d3d12core.so
    # OpenAL
    libopenal.so libopenal.so.1
    # Vendor
    libEOSSDK-Linux-Shipping.so libsteam_api.so
    # Managed
    Steamworks.NET.dll
    # Licenses
    LICENSES/DXVK-LICENSE.txt
    LICENSES/EOS-NOTICE.txt
    LICENSES/FFmpeg-LGPL-2.1.txt
    LICENSES/FFmpeg-README.txt
    LICENSES/OpenAL-Soft-LGPL-2.0.txt
    LICENSES/OpenAL-Soft-NOTICES.txt
    LICENSES/OpenAL-Soft-README.txt
    LICENSES/README.txt
    LICENSES/Steam-NOTICE.txt
    LICENSES/Steamworks.NET-LICENSE.txt
    LICENSES/VKD3D-LGPL-2.1.txt
    LICENSES/vkd3d-proton-README.txt
)

EXPECTED_FILES_SE2=(
    # DXVK (patched, identical to the SE1 archive's copy)
    libdxvk_d3d11.so libdxvk_d3d11.so.0
    libdxvk_dxgi.so  libdxvk_dxgi.so.0
    # vkd3d-proton (patched, identical to the SE1 archive's copy)
    libvkd3d-proton-d3d12.so libvkd3d-proton-d3d12core.so
    # FMOD (vendor blobs, file names carry the SONAMEs)
    libfmod.so.14
    libfmodstudio.so.14
    # Licenses
    LICENSES/DXVK-LICENSE.txt
    LICENSES/FMOD-EULA.txt
    LICENSES/FMOD-NOTICE.txt
    LICENSES/README.txt
    LICENSES/VKD3D-LGPL-2.1.txt
    LICENSES/vkd3d-proton-README.txt
)

MISSING=0
for rel in "${EXPECTED_FILES[@]}"; do
    if [ ! -e "$LIBRARIES_DIR/$rel" ]; then
        echo "MISSING: $LIBRARIES_DIR/$rel" >&2
        MISSING=1
    fi
done
for rel in "${EXPECTED_FILES_SE2[@]}"; do
    if [ ! -e "$LIBRARIES_SE2_DIR/$rel" ]; then
        echo "MISSING: $LIBRARIES_SE2_DIR/$rel" >&2
        MISSING=1
    fi
done
if [ "$MISSING" = "1" ]; then
    if [ "$FILTERED" = "1" ]; then
        echo "Note: --only/--skip filters were active; partial staging is expected." >&2
        exit 0
    fi
    echo "ERROR: dependency staging is incomplete." >&2
    exit 1
fi

echo
echo "==> All expected artefacts present in $LIBRARIES_DIR"
( cd "$LIBRARIES_DIR" && ls -lh | sed 's/^/  /' )
echo
echo "==> All expected artefacts present in $LIBRARIES_SE2_DIR"
( cd "$LIBRARIES_SE2_DIR" && ls -lh | sed 's/^/  /' )

# ---- 11. package ------------------------------------------------------------
# Each archive mirrors its staging tree exactly: every library at the archive
# root plus a LICENSES/ subdir. Consumers extract it straight into their own
# Libraries staging folder, so any layout change here is a breaking change
# for them — see docs/release-archive.md.
#
# Symlinks are stored AS symlinks (tar's default), which is what keeps the
# libavcodec.so -> .so.62 -> .so.62.28.100 chain intact on extraction and the
# archives small.

if [ "$FILTERED" = "1" ]; then
    echo
    echo "==> Skipping packaging (--only/--skip filters were active)"
    exit 0
fi

if [ "$DO_PACKAGE" = "0" ]; then
    echo
    echo "==> Skipping packaging (--no-package)"
    exit 0
fi

package_archive() {
    # package_archive <staging dir> <archive name>
    local staging="$1" archive="$2"
    echo
    echo "############################################################"
    echo "# build: packaging -> $OUTPUT_DIR/$archive"
    echo "############################################################"
    rm -f "$OUTPUT_DIR/$archive"
    # --sort=name + a fixed mtime/owner make the archive byte-reproducible for
    # a given set of inputs, so an unchanged rebuild produces an identical file.
    tar --sort=name \
        --owner=0 --group=0 --numeric-owner \
        --mtime='UTC 2020-01-01' \
        -czf "$OUTPUT_DIR/$archive" \
        -C "$staging" .
    echo "==> Archive contents:"
    tar -tzf "$OUTPUT_DIR/$archive" | sed 's/^/  /'
}

mkdir -p "$OUTPUT_DIR"

package_archive "$LIBRARIES_DIR" "$ARCHIVE_NAME"
package_archive "$LIBRARIES_SE2_DIR" "$ARCHIVE_NAME_SE2"

echo
echo "############################################################"
echo "# DONE  $(du -h "$OUTPUT_DIR/$ARCHIVE_NAME" | awk '{print $1}')  $OUTPUT_DIR/$ARCHIVE_NAME"
echo "# DONE  $(du -h "$OUTPUT_DIR/$ARCHIVE_NAME_SE2" | awk '{print $1}')  $OUTPUT_DIR/$ARCHIVE_NAME_SE2"
echo "############################################################"
