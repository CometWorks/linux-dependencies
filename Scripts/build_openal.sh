#!/usr/bin/env bash
# build_openal.sh
#
# Builds OpenAL Soft from the upstream release tarball and installs
# libopenal.so (plus its SONAME alias) into the build/Libraries staging
# folder.
#
# Space Engineers' audio on Linux goes through Silk.NET.OpenAL (used by
# se-linux-compat), which dlopens libopenal at runtime. Neither the
# freedesktop Flatpak runtime nor a minimal desktop install is guaranteed to
# ship it, and until now Pulsar handled it three different ways depending on
# the bundle: compiled from source inside the Flatpak manifest, and left to
# LinuxCompat's Assets/ or the host for the developer 7z. Building it here
# gives both bundles the same pinned binary.
#
# The version and tarball checksum match what Pulsar's Flatpak manifest built
# before this moved here, so the shipped library is the one that was already
# being tested.
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── Libraries/                       staging dir all dep scripts populate
#   ├── openal-soft-$VERSION.tar.bz2     downloaded tarball (cached)
#   ├── openal-soft-$VERSION/            extracted source tree (cached)
#   │   └── _build/                      cmake build dir
#   └── openal.stamp                     last-built version (cache key)
#
# Usage:
#   ./build_openal.sh           Build (or no-op if cached).
#   ./build_openal.sh --clean   Wipe build dirs and rebuild from scratch.
#   ./build_openal.sh --print-stamp
#                               Print this build's cache stamp and exit without
#                               touching the network. The value is the content
#                               key CI caches the staged libraries under; see
#                               docs/building.md.
#
# Env-var overrides (defaults shown):
#   OPENAL_VERSION = 1.25.2
#   OPENAL_SHA256  = 1dbaac44e7579d5bc8847ca8db4b2e8b9fd3961041f35ee20def4958301e1089
#   BUILD_DIR      = <repo>/build
#   LIBRARIES_DIR  = $BUILD_DIR/Libraries
#   JOBS           = $(nproc)
#
# Requirements: cmake, gcc, g++, make (or ninja), curl, tar, patchelf, readelf.

set -euo pipefail

OPENAL_VERSION="${OPENAL_VERSION:-1.25.2}"
OPENAL_SHA256="${OPENAL_SHA256:-1dbaac44e7579d5bc8847ca8db4b2e8b9fd3961041f35ee20def4958301e1089}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"
LIBRARIES_DIR="${LIBRARIES_DIR:-$BUILD_DIR/Libraries}"
JOBS="${JOBS:-$(nproc)}"

OPENAL_TARBALL="$BUILD_DIR/openal-soft-$OPENAL_VERSION.tar.bz2"
OPENAL_SRC_DIR="$BUILD_DIR/openal-soft-$OPENAL_VERSION"
OPENAL_BUILD_DIR="$OPENAL_SRC_DIR/_build"
STAGE_DIR="$OPENAL_BUILD_DIR/_install"
STAMP_FILE="$BUILD_DIR/openal.stamp"
STAMP_CONTENT="$OPENAL_VERSION"

OPENAL_URL="https://openal-soft.org/openal-releases/openal-soft-$OPENAL_VERSION.tar.bz2"

# The SONAME upstream produces. Asserted after the build: a major-version bump
# would change it, and anything dlopening the old name at runtime would then
# silently miss the bundled copy.
EXPECTED_SONAME="libopenal.so.1"

CLEAN=0
PRINT_STAMP=0
for arg in "$@"; do
    case "$arg" in
        --clean)       CLEAN=1 ;;
        --print-stamp) PRINT_STAMP=1 ;;
        -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$PRINT_STAMP" = "1" ]; then
    printf '%s\n' "$STAMP_CONTENT"
    exit 0
fi

# ---- preflight --------------------------------------------------------------

for tool in cmake gcc g++ curl tar patchelf readelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done

mkdir -p "$BUILD_DIR" "$LIBRARIES_DIR"

# ---- cache check ------------------------------------------------------------

if [ "$CLEAN" = "1" ]; then
    rm -rf "$OPENAL_SRC_DIR"
elif [ -e "$LIBRARIES_DIR/libopenal.so" ] \
   && [ ! -L "$LIBRARIES_DIR/libopenal.so" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
    echo "==> Cached build matches OpenAL Soft $OPENAL_VERSION; skipping rebuild"
    ( cd "$LIBRARIES_DIR" && ls -1 libopenal.so* )
    exit 0
fi

# ---- download (cached, checksum-verified) ----------------------------------
# Unlike the git-tag clones elsewhere in this repo, a tarball URL is mutable,
# so the checksum is the pin. It is the same one Pulsar's Flatpak manifest
# used, which is what makes this a move rather than a new dependency.

if [ ! -f "$OPENAL_TARBALL" ]; then
    echo "==> Downloading $OPENAL_URL"
    tmp="$OPENAL_TARBALL.partial"
    rm -f "$tmp"
    curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$OPENAL_URL"
    mv "$tmp" "$OPENAL_TARBALL"
else
    echo "==> Using cached tarball $OPENAL_TARBALL"
fi

echo "==> Verifying tarball checksum"
actual="$(sha256sum "$OPENAL_TARBALL" | awk '{print $1}')"
if [ "$actual" != "$OPENAL_SHA256" ]; then
    echo "ERROR: checksum mismatch for $OPENAL_TARBALL" >&2
    echo "       expected $OPENAL_SHA256" >&2
    echo "       actual   $actual" >&2
    echo "       Delete the file to re-download, or update OPENAL_SHA256 if" >&2
    echo "       the version was bumped deliberately." >&2
    exit 1
fi

# ---- extract (cached) -------------------------------------------------------

if [ ! -f "$OPENAL_SRC_DIR/CMakeLists.txt" ]; then
    echo "==> Extracting $OPENAL_TARBALL -> $OPENAL_SRC_DIR"
    rm -rf "$OPENAL_SRC_DIR"
    mkdir -p "$OPENAL_SRC_DIR"
    tar -xf "$OPENAL_TARBALL" -C "$OPENAL_SRC_DIR" --strip-components=1
    [ -f "$OPENAL_SRC_DIR/CMakeLists.txt" ] || {
        echo "ERROR: extraction did not produce $OPENAL_SRC_DIR/CMakeLists.txt" >&2
        exit 1
    }
else
    echo "==> Using cached source tree $OPENAL_SRC_DIR"
fi

# ---- configure + build + install -------------------------------------------
# Beyond the three options Pulsar's Flatpak manifest used (no command-line
# utils, no examples, no /etc config file), every audio backend is pinned
# explicitly. That matters more than it looks:
#
# OpenAL compiles a backend in only when its development headers are present
# at build time, and then dlopens the actual library at runtime. Leaving that
# to autodetection would mean a build host without libpulse-dev silently
# produces a libopenal with no PulseAudio backend at all - a library that
# loads fine and then plays no sound. REQUIRE_* turns each of those into a
# configure-time failure instead.
#
# Enabled: PipeWire, PulseAudio, ALSA (required - the three that matter on a
# modern desktop), plus OSS, which needs no library. Disabled: JACK and
# PortAudio (niche, and each would add a dev package to the runner), SndIO
# (BSD-oriented), and SDL2/SDL3 - the SDL backend is off upstream by default
# because it adds a runtime dependency, and we do not ship SDL.
#
# CMAKE_DISABLE_FIND_PACKAGE_SDL3 stops the unconditional find_package(SDL3)
# at the top of upstream's CMakeLists from tripping over whatever SDL3 install
# the build host happens to have. Without it a broken or partial system SDL3
# fails the configure outright, even though the backend is off.
#
# Because the backends are dlopened rather than linked, none of these appear
# as NEEDED entries - the dependency check below enforces that.

rm -rf "$STAGE_DIR"

echo "==> Configuring OpenAL Soft $OPENAL_VERSION"
cmake -S "$OPENAL_SRC_DIR" -B "$OPENAL_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$STAGE_DIR" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DLIBTYPE=SHARED \
    -DALSOFT_UTILS=OFF \
    -DALSOFT_EXAMPLES=OFF \
    -DALSOFT_INSTALL_CONFIG=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_SDL3=ON \
    -DALSOFT_BACKEND_PIPEWIRE=ON   -DALSOFT_REQUIRE_PIPEWIRE=ON \
    -DALSOFT_BACKEND_PULSEAUDIO=ON -DALSOFT_REQUIRE_PULSEAUDIO=ON \
    -DALSOFT_BACKEND_ALSA=ON       -DALSOFT_REQUIRE_ALSA=ON \
    -DALSOFT_BACKEND_OSS=ON \
    -DALSOFT_BACKEND_JACK=OFF \
    -DALSOFT_BACKEND_PORTAUDIO=OFF \
    -DALSOFT_BACKEND_SNDIO=OFF \
    -DALSOFT_BACKEND_SDL2=OFF \
    -DALSOFT_BACKEND_SDL3=OFF

echo "==> Building OpenAL Soft with -j$JOBS"
cmake --build "$OPENAL_BUILD_DIR" -j "$JOBS"

echo "==> Installing into $STAGE_DIR"
cmake --install "$OPENAL_BUILD_DIR" >/dev/null

LIB_SRC="$STAGE_DIR/lib"
[ -d "$LIB_SRC" ] || { echo "ERROR: $LIB_SRC missing after install" >&2; exit 1; }

# ---- verify the SONAME ------------------------------------------------------
# Silk.NET.OpenAL dlopens by SONAME, so a bump here would leave the bundled
# copy unused while the app silently fell back to the host's (or found none).

SONAME="$(readelf -d "$LIB_SRC/libopenal.so" 2>/dev/null \
          | awk '/\(SONAME\)/ {match($0, /\[.*\]/); print substr($0, RSTART+1, RLENGTH-2)}')"
if [ "$SONAME" != "$EXPECTED_SONAME" ]; then
    echo "ERROR: expected SONAME '$EXPECTED_SONAME', got '$SONAME'." >&2
    echo "       A SONAME bump means anything dlopening the old name will not" >&2
    echo "       find the bundled library. Update EXPECTED_SONAME here and the" >&2
    echo "       expected-file lists in build.sh and the consumers together." >&2
    exit 1
fi

# ---- patch DT_RUNPATH=$ORIGIN ----------------------------------------------
# Parity with the FFmpeg and DXVK payloads, so the library resolves anything
# it needs from its own directory rather than the host's search path.

echo "==> Patching DT_RUNPATH=\$ORIGIN onto libopenal"
REAL_LIB="$(readlink -f "$LIB_SRC/libopenal.so")"
patchelf --set-rpath '$ORIGIN' "$REAL_LIB"

# ---- verify runtime dependencies -------------------------------------------
# Wider than FFmpeg's allow-list: OpenAL is C++, so libstdc++ and libgcc_s are
# expected. Everything else (libpulse, libasound, ...) must stay absent - those
# backends are dlopened at runtime, and a NEEDED entry for one would make the
# bundle hard-require that specific audio stack.

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
done < <(ldd "$REAL_LIB" | sed 's/^[[:space:]]*//')
if [ "$DEP_LEAK" = "1" ]; then
    echo "ERROR: libopenal has an unexpected runtime dependency." >&2
    echo "       Audio backends are meant to be dlopened, not linked." >&2
    exit 1
fi

# ---- stage ------------------------------------------------------------------
# Ship the real file under the bare unversioned name — the archives carry no
# symlinks and no version-suffixed filenames. The SONAME inside the binary is
# left as upstream produced it (asserted above); consumers load the library
# by file name. Clear the previous build's files first so a version bump (or
# the pre-bare-name layout) cannot leave a stale copy behind.

echo "==> Staging OpenAL into $LIBRARIES_DIR"
find "$LIBRARIES_DIR" -maxdepth 1 -name 'libopenal.so*' -delete

install -m 0755 "$REAL_LIB" "$LIBRARIES_DIR/libopenal.so"

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

echo
echo "==> Staged OpenAL Soft $OPENAL_VERSION into $LIBRARIES_DIR:"
( cd "$LIBRARIES_DIR" && ls -1 libopenal.so* )
