#!/usr/bin/env bash
# build.sh
#
# Top-level orchestrator for the Space Engineers Linux binary dependencies.
# Builds every library from source, stages the results in build/Libraries/
# (Space Engineers 1) and build/Libraries-SE2/ (Space Engineers 2), verifies
# both staged trees, and packages them as two release archives:
#
#   dist/linux-dependencies.tar.gz       SE1 (Pulsar for Linux, Magnetar)
#   dist/linux-dependencies-se2.tar.gz   SE2 (patched DXVK + FMOD)
#
# Pipeline (in order):
#
#   1. Scripts/build_ffmpeg.sh          FFmpeg 8.1 (libav*.so* / libsw*.so*)
#   2. Scripts/build_dxvk.sh            DXVK Native v2.7.1, pristine upstream
#                                       (libdxvk_d3d11.so + libdxvk_dxgi.so + .0 links)
#   3. Scripts/build_dxvk.sh --se2      DXVK Native v2.7.1 + Patches/dxvk/
#                                       series, staged into Libraries-SE2/
#   4. Scripts/build_openal.sh          OpenAL Soft 1.25.2 (libopenal.so*)
#   5. Scripts/build_steamworks_net.sh  Steamworks.NET.dll
#   6. Vendor copy:                     libEOSSDK-Linux-Shipping.so + libsteam_api.so
#                                       (proprietary, committed under Vendor/)
#   7. SE2 vendor copy:                 libfmod.so + libfmodstudio.so from
#                                       Vendor/se2/ (proprietary, Firelight).
#                                       If absent, the SE2 archive is SKIPPED
#                                       with a warning — see Vendor/se2/README.md.
#   8. License copy:                    Licenses/*.txt -> LICENSES/ (SE1),
#                                       DXVK + Licenses/se2/*.txt -> LICENSES/ (SE2)
#   9. Final assertion:                 every expected artefact is present
#  10. Package:                         both archives under dist/
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
STEP_NAMES="ffmpeg dxvk dxvk-se2 openal steamworks-net"
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
run_step dxvk-se2       "$SCRIPTS_DIR/build_dxvk.sh" --se2
run_step openal         "$SCRIPTS_DIR/build_openal.sh"
run_step steamworks-net "$SCRIPTS_DIR/build_steamworks_net.sh"

# ---- 6. Vendor blobs --------------------------------------------------------

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

# ---- 7. SE2 vendor blobs (FMOD) ---------------------------------------------
# The FMOD Engine runtime for the Space Engineers 2 client, committed under
# Vendor/se2/ (the download is login-gated, like EOS and Steamworks). Unlike
# those, FMOD is OPTIONAL while the SE2 pipeline bootstraps: when the blobs
# are absent the SE2 archive is skipped with a prominent warning instead of
# failing the build, so the SE1 archive keeps shipping. Committing the blobs
# is what activates the SE2 release asset — see Vendor/se2/README.md.

echo
echo "############################################################"
echo "# build: SE2 vendor blobs (Vendor/se2/ -> Libraries-SE2/)"
echo "############################################################"
SE2_BLOBS=(libfmod.so libfmodstudio.so)
SE2_READY=1
for blob in "${SE2_BLOBS[@]}"; do
    [ -f "$VENDOR_DIR/se2/$blob" ] || SE2_READY=0
done
if [ "$SE2_READY" = "1" ]; then
    for blob in "${SE2_BLOBS[@]}"; do
        install -m 0755 "$VENDOR_DIR/se2/$blob" "$LIBRARIES_SE2_DIR/$blob"
        # libfmodstudio's NEEDED entry references libfmod by SONAME
        # (e.g. libfmod.so.14), so stage a matching alias symlink next to
        # the real file. The SONAME is read from the blob rather than
        # hard-coded, so an FMOD update cannot desynchronize the alias.
        soname="$(readelf -d "$LIBRARIES_SE2_DIR/$blob" \
                  | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')"
        if [ -n "$soname" ] && [ "$soname" != "$blob" ]; then
            ln -sfn "$blob" "$LIBRARIES_SE2_DIR/$soname"
        fi
        echo "  copied $blob${soname:+ (SONAME alias: $soname)}"
    done
else
    echo "WARNING: FMOD vendor blobs not found under $VENDOR_DIR/se2/" >&2
    echo "         The SE2 archive ($ARCHIVE_NAME_SE2) will NOT be packaged." >&2
    echo "         See Vendor/se2/README.md for how to obtain and commit them." >&2
fi

# ---- 8. Licenses ------------------------------------------------------------
# SE1 archive: every top-level Licenses/*.txt. SE2 archive: the shared DXVK
# licence plus the SE2-specific notices under Licenses/se2/ (kept in a
# subdirectory precisely so the SE1 glob below does not pick them up).

echo
echo "############################################################"
echo "# build: licenses (Licenses/ -> Libraries/LICENSES/)"
echo "############################################################"
shopt -s nullglob
for f in "$LICENSES_SRC"/*.txt; do
    install -m 0644 "$f" "$LIBRARIES_DIR/LICENSES/$(basename "$f")"
    echo "  copied $(basename "$f")"
done
install -m 0644 "$LICENSES_SRC/DXVK-LICENSE.txt" \
    "$LIBRARIES_SE2_DIR/LICENSES/DXVK-LICENSE.txt"
echo "  copied DXVK-LICENSE.txt (SE2)"
for f in "$LICENSES_SRC"/se2/*.txt; do
    install -m 0644 "$f" "$LIBRARIES_SE2_DIR/LICENSES/$(basename "$f")"
    echo "  copied $(basename "$f") (SE2)"
done
shopt -u nullglob

# ---- 9. final assertion ----------------------------------------------------
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

# The SE2 tree is asserted only when the FMOD blobs are present; without them
# the SE2 archive is skipped anyway (see step 7), and failing the SE1 release
# over a not-yet-bootstrapped SE2 payload would be wrong.
EXPECTED_FILES_SE2=(
    # DXVK (patched variant)
    libdxvk_d3d11.so libdxvk_d3d11.so.0
    libdxvk_dxgi.so  libdxvk_dxgi.so.0
    # FMOD (vendor blobs; SONAME alias symlinks are staged next to them,
    # but their names depend on the blob version so they are not listed)
    libfmod.so
    libfmodstudio.so
    # Licenses
    LICENSES/DXVK-LICENSE.txt
    LICENSES/FMOD-NOTICE.txt
    LICENSES/README.txt
)

MISSING=0
for rel in "${EXPECTED_FILES[@]}"; do
    if [ ! -e "$LIBRARIES_DIR/$rel" ]; then
        echo "MISSING: $LIBRARIES_DIR/$rel" >&2
        MISSING=1
    fi
done
if [ "$SE2_READY" = "1" ]; then
    for rel in "${EXPECTED_FILES_SE2[@]}"; do
        if [ ! -e "$LIBRARIES_SE2_DIR/$rel" ]; then
            echo "MISSING: $LIBRARIES_SE2_DIR/$rel" >&2
            MISSING=1
        fi
    done
fi
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
if [ "$SE2_READY" = "1" ]; then
    echo
    echo "==> All expected artefacts present in $LIBRARIES_SE2_DIR"
    ( cd "$LIBRARIES_SE2_DIR" && ls -lh | sed 's/^/  /' )
fi

# ---- 10. package ------------------------------------------------------------
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

if [ "$SE2_READY" = "1" ]; then
    package_archive "$LIBRARIES_SE2_DIR" "$ARCHIVE_NAME_SE2"
else
    # Also remove any stale SE2 archive from a previous run, so a build
    # without the FMOD blobs cannot leave an outdated asset lying around
    # for the CI upload step to pick up.
    rm -f "$OUTPUT_DIR/$ARCHIVE_NAME_SE2"
    echo
    echo "==> SKIPPING the SE2 archive: FMOD vendor blobs are absent" >&2
    echo "    (see Vendor/se2/README.md for how to obtain and commit them)" >&2
fi

echo
echo "############################################################"
echo "# DONE  $(du -h "$OUTPUT_DIR/$ARCHIVE_NAME" | awk '{print $1}')  $OUTPUT_DIR/$ARCHIVE_NAME"
if [ "$SE2_READY" = "1" ]; then
    echo "# DONE  $(du -h "$OUTPUT_DIR/$ARCHIVE_NAME_SE2" | awk '{print $1}')  $OUTPUT_DIR/$ARCHIVE_NAME_SE2"
fi
echo "############################################################"
