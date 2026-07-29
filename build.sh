#!/usr/bin/env bash
# build.sh
#
# Top-level orchestrator for the Space Engineers Linux binary dependencies.
# Builds every library from source, stages the result in build/Libraries/,
# verifies the staged tree, and packages it as the release archive
# dist/linux-dependencies.tar.gz.
#
# Pipeline (in order):
#
#   1. Scripts/build_ffmpeg.sh          FFmpeg 8.1 (libav*.so* / libsw*.so*)
#   2. Scripts/build_dxvk.sh            DXVK Native v2.7.1
#                                       (libdxvk_d3d11.so + libdxvk_dxgi.so + .0 links)
#   3. Scripts/build_openal.sh          OpenAL Soft 1.25.2 (libopenal.so*)
#   4. Scripts/build_steamworks_net.sh  Steamworks.NET.dll
#   5. Vendor copy:                     libEOSSDK-Linux-Shipping.so + libsteam_api.so
#                                       (proprietary, committed under Vendor/)
#   6. License copy:                    Licenses/*.txt -> LICENSES/ subdir
#   7. Final assertion:                 every expected artefact is present
#   8. Package:                         dist/linux-dependencies.tar.gz
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
#   REPO_DIR      = <dir of this script>
#   BUILD_DIR     = $REPO_DIR/build
#   LIBRARIES_DIR = $BUILD_DIR/Libraries
#   OUTPUT_DIR    = $REPO_DIR/dist
#   VENDOR_DIR    = $REPO_DIR/Vendor
#   LICENSES_SRC  = $REPO_DIR/Licenses
#   JOBS          = $(nproc)
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
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_DIR/dist}"
VENDOR_DIR="${VENDOR_DIR:-$REPO_DIR/Vendor}"
LICENSES_SRC="${LICENSES_SRC:-$REPO_DIR/Licenses}"

ARCHIVE_NAME="linux-dependencies.tar.gz"

export REPO_DIR BUILD_DIR LIBRARIES_DIR

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
STEP_NAMES="ffmpeg dxvk openal steamworks-net"
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

mkdir -p "$LIBRARIES_DIR/LICENSES"

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

echo "==> Repo dir    : $REPO_DIR"
echo "==> Build dir   : $BUILD_DIR"
echo "==> Staging dir : $LIBRARIES_DIR"
echo "==> Output dir  : $OUTPUT_DIR"

# ---- 1..4. per-dependency build scripts ------------------------------------

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
run_step openal         "$SCRIPTS_DIR/build_openal.sh"
run_step steamworks-net "$SCRIPTS_DIR/build_steamworks_net.sh"

# ---- 5. Vendor blobs --------------------------------------------------------

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

# ---- 6. Licenses ------------------------------------------------------------

echo
echo "############################################################"
echo "# build: licenses (Licenses/ -> Libraries/LICENSES/)"
echo "############################################################"
shopt -s nullglob
for f in "$LICENSES_SRC"/*.txt; do
    install -m 0644 "$f" "$LIBRARIES_DIR/LICENSES/$(basename "$f")"
    echo "  copied $(basename "$f")"
done
shopt -u nullglob

# ---- 7. final assertion ----------------------------------------------------
# Confirm every artefact every consumer expects is present. Missing files here
# are far easier to debug than a cryptic failure inside a consumer's build.
#
# Keep this list in sync with docs/release-archive.md, which is the contract
# the consuming repos (Pulsar for Linux, Magnetar) rely on.

EXPECTED_FILES=(
    # FFmpeg
    libavcodec.so libavcodec.so.62 libavcodec.so.62.28.100
    libavformat.so libavformat.so.62 libavformat.so.62.12.100
    libavutil.so libavutil.so.60 libavutil.so.60.26.100
    libswresample.so libswresample.so.6 libswresample.so.6.3.100
    libswscale.so libswscale.so.9 libswscale.so.9.5.100
    # DXVK
    libdxvk_d3d11.so libdxvk_d3d11.so.0
    libdxvk_dxgi.so  libdxvk_dxgi.so.0
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
)

MISSING=0
for rel in "${EXPECTED_FILES[@]}"; do
    if [ ! -e "$LIBRARIES_DIR/$rel" ]; then
        echo "MISSING: $LIBRARIES_DIR/$rel" >&2
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

# ---- 8. package -------------------------------------------------------------
# The archive mirrors build/Libraries/ exactly: every library at the archive
# root plus a LICENSES/ subdir. Consumers extract it straight into their own
# Libraries staging folder, so any layout change here is a breaking change
# for them — see docs/release-archive.md.
#
# Symlinks are stored AS symlinks (tar's default), which is what keeps the
# libavcodec.so -> .so.62 -> .so.62.28.100 chain intact on extraction and the
# archive small.

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

echo
echo "############################################################"
echo "# build: packaging -> $OUTPUT_DIR/$ARCHIVE_NAME"
echo "############################################################"

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/$ARCHIVE_NAME"

# --sort=name + a fixed mtime/owner make the archive byte-reproducible for a
# given set of inputs, so an unchanged rebuild produces an identical file.
tar --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime='UTC 2020-01-01' \
    -czf "$OUTPUT_DIR/$ARCHIVE_NAME" \
    -C "$LIBRARIES_DIR" .

echo "==> Archive contents:"
tar -tzf "$OUTPUT_DIR/$ARCHIVE_NAME" | sed 's/^/  /'

echo
echo "############################################################"
echo "# DONE  $(du -h "$OUTPUT_DIR/$ARCHIVE_NAME" | awk '{print $1}')  $OUTPUT_DIR/$ARCHIVE_NAME"
echo "############################################################"
