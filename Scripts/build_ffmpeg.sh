#!/usr/bin/env bash
# build_ffmpeg.sh
#
# Builds FFmpeg 8.1 from source as a set of self-contained shared libraries
# (libavcodec.so.62, libavformat.so.62, libavutil.so.60, libswresample.so.6,
# libswscale.so.9) and installs them into the build/Libraries staging folder
# (gitignored; packaged into the release archive by ../build.sh).
#
# "Self-contained" here means: built with --disable-* for every optional
# external codec / hwaccel / network / device backend, so the resulting .so
# files only depend on glibc + libm + libpthread + libz (verified post-build
# via ldd). They do NOT pull in libx264/libxcb/libdrm/libpulse/etc. from
# the host. This is what FFmpeg.AutoGen 8.1 P/Invokes against - see the
# LibraryVersionMap in Pulsar's ClientPlugin/Audio/MySdlAudioInterop.cs.
#
# Source layout (all under the gitignored build/ folder of this repo):
#
#   build/
#   ├── ffmpeg-8.1.tar.xz       downloaded tarball (cached across runs)
#   └── ffmpeg-8.1/             extracted source tree (cached)
#       └── _build/             out-of-tree configure + make output (cached)
#           └── _install/       staging prefix the final libs are copied from
#
# A cold first run downloads + extracts + configures + builds; every
# subsequent run is a fast incremental `make` against the cached objects.
# Wipe build/ffmpeg-$FFMPEG_VERSION/ to force a re-extract + reconfigure;
# delete build/ffmpeg-$FFMPEG_VERSION.tar.xz to force a re-download.
#
# Usage:
#   ./build_ffmpeg.sh           Download (if needed), build, install to LIBRARIES_DIR.
#   ./build_ffmpeg.sh --clean   Wipe the cached source + build dirs and rebuild.
#   ./build_ffmpeg.sh --print-stamp
#                               Print this build's cache stamp and exit without
#                               touching the network or the build tree. The
#                               value is the content key CI caches the staged
#                               libraries under; see docs/building.md.
#
# Env-var overrides (defaults shown):
#   FFMPEG_VERSION   = 8.1
#   BUILD_DIR        = <repo>/build
#   FFMPEG_TARBALL   = $BUILD_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz
#   FFMPEG_SRC_DIR   = $BUILD_DIR/ffmpeg-$FFMPEG_VERSION
#   FFMPEG_BUILD_DIR = $FFMPEG_SRC_DIR/_build
#   LIBRARIES_DIR    = $BUILD_DIR/Libraries
#   JOBS             = $(nproc)
#
# Requirements: gcc, make, pkg-config, curl, nasm OR yasm (for x86 SIMD).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build}"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1}"
FFMPEG_TARBALL="${FFMPEG_TARBALL:-$BUILD_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz}"
FFMPEG_SRC_DIR="${FFMPEG_SRC_DIR:-$BUILD_DIR/ffmpeg-$FFMPEG_VERSION}"
FFMPEG_BUILD_DIR="${FFMPEG_BUILD_DIR:-$FFMPEG_SRC_DIR/_build}"
LIBRARIES_DIR="${LIBRARIES_DIR:-$BUILD_DIR/Libraries}"
JOBS="${JOBS:-$(nproc)}"

FFMPEG_TARBALL_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

STAMP_FILE="$BUILD_DIR/ffmpeg.stamp"
EXPECTED_LIBS=(libavcodec.so libavformat.so libavutil.so
               libswresample.so libswscale.so)

CLEAN=0
PRINT_STAMP=0
for arg in "$@"; do
    case "$arg" in
        --clean)       CLEAN=1 ;;
        --print-stamp) PRINT_STAMP=1 ;;
        -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# The configure flags are half of what determines the shipped binaries, so
# they belong in the cache stamp. The array lives here, rather than beside
# the rationale in the configure section below, so --print-stamp can hash it
# without downloading or extracting anything. --prefix is deliberately NOT
# part of it: it is a build-tree path, which would make the stamp differ
# between two machines building the identical thing.

FFMPEG_CONFIGURE_FLAGS=(
    --cpu=x86-64-v2
    --enable-shared
    --disable-static
    --enable-pic
    --disable-programs
    --disable-doc
    --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
    --disable-debug
    --disable-network
    --disable-avdevice --disable-avfilter
    --disable-vaapi --disable-vdpau
    --disable-libdrm --disable-xlib
    --disable-vulkan
    --disable-bzlib --disable-lzma --disable-iconv
    --disable-sdl2
    --disable-alsa
    --extra-ldflags="-Wl,-Bsymbolic"
)

CONFIG_HASH="$(printf '%s\n' "${FFMPEG_CONFIGURE_FLAGS[@]}" | sha256sum | cut -d' ' -f1)"
STAMP_CONTENT="$FFMPEG_VERSION flags=$CONFIG_HASH"

if [ "$PRINT_STAMP" = "1" ]; then
    printf '%s\n' "$STAMP_CONTENT"
    exit 0
fi

# ---- preflight --------------------------------------------------------------

for tool in gcc make pkg-config curl tar readelf patchelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done
if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
    echo "ERROR: need nasm or yasm for FFmpeg x86 SIMD" >&2
    exit 1
fi

mkdir -p "$LIBRARIES_DIR"
LIBRARIES_DIR="$(cd "$LIBRARIES_DIR" && pwd)"
mkdir -p "$(dirname "$FFMPEG_TARBALL")"

# ---- cache check ------------------------------------------------------------
# Same contract as the sibling build scripts: when the staged libraries are
# already there and the stamp matches this configuration, there is nothing to
# do. Skipping the whole step (rather than relying on an incremental `make`)
# is what lets CI restore the staged files from a cache and move on without a
# source tree at all.

if [ "$CLEAN" = "1" ]; then
    if [ -d "$FFMPEG_SRC_DIR" ]; then
        echo "==> --clean: wiping cached source tree $FFMPEG_SRC_DIR"
        rm -rf "$FFMPEG_SRC_DIR"
    fi
else
    ALL_LIBS_PRESENT=1
    for lib in "${EXPECTED_LIBS[@]}"; do
        [ -e "$LIBRARIES_DIR/$lib" ] || ALL_LIBS_PRESENT=0
    done
    if [ "$ALL_LIBS_PRESENT" = "1" ] \
       && [ -f "$STAMP_FILE" ] \
       && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
        echo "==> Cached build matches FFmpeg $FFMPEG_VERSION; skipping rebuild"
        echo "==> FFmpeg libs already in $LIBRARIES_DIR:"
        ( cd "$LIBRARIES_DIR" && ls -1 libav*.so* libsw*.so* )
        exit 0
    fi
fi

# ---- download tarball (cached) ---------------------------------------------

if [ ! -f "$FFMPEG_TARBALL" ]; then
    echo "==> Downloading $FFMPEG_TARBALL_URL"
    echo "    -> $FFMPEG_TARBALL"
    tmp="$FFMPEG_TARBALL.partial"
    rm -f "$tmp"
    curl -fL --retry 3 --retry-delay 5 -o "$tmp" "$FFMPEG_TARBALL_URL"
    mv "$tmp" "$FFMPEG_TARBALL"
else
    echo "==> Using cached tarball $FFMPEG_TARBALL"
fi

# ---- extract (cached) ------------------------------------------------------
# A "sane" extracted tree is one that contains the upstream `configure`
# script. If the marker is missing the tree is rebuilt from the tarball.

if [ ! -x "$FFMPEG_SRC_DIR/configure" ]; then
    echo "==> Extracting $FFMPEG_TARBALL -> $FFMPEG_SRC_DIR"
    rm -rf "$FFMPEG_SRC_DIR"
    mkdir -p "$(dirname "$FFMPEG_SRC_DIR")"
    # The tarball has a top-level ffmpeg-$VERSION/ dir; strip it so the
    # contents land directly in $FFMPEG_SRC_DIR regardless of how the
    # caller named that dir.
    mkdir -p "$FFMPEG_SRC_DIR"
    tar -xf "$FFMPEG_TARBALL" -C "$FFMPEG_SRC_DIR" --strip-components=1
    [ -x "$FFMPEG_SRC_DIR/configure" ] || {
        echo "ERROR: extraction did not produce $FFMPEG_SRC_DIR/configure" >&2
        exit 1
    }
else
    echo "==> Using cached source tree $FFMPEG_SRC_DIR"
fi

mkdir -p "$FFMPEG_BUILD_DIR"

STAGE_DIR="$FFMPEG_BUILD_DIR/_install"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# ---- configure --------------------------------------------------------------
# Notes on the disable list (all flags verified against
# `configure --help` for FFmpeg 8.1 — flags that don't exist in 8.1 have
# been omitted, see comment block at the bottom):
#   --disable-programs       no ffmpeg/ffplay/ffprobe binaries (we just want libs)
#   --disable-doc / *pages   skip texinfo/manpage build (saves time, no value)
#   --disable-network        drop tls/sctp/openssl/gnutls dep chain
#   --disable-avdevice       skip alsa/pulse/x11grab/sdl input backends
#                            (also kills the implicit libxcb / libjack /
#                            libpulse pulls — those only matter when
#                            avdevice is built)
#   --disable-avfilter       skip filter graph (we only decode)
#   --disable-vaapi/vdpau    skip VA-API / VDPAU hwaccel (avoids libva, libvdpau)
#   --disable-libdrm         no libdrm dep
#   --disable-xlib           no X11 dep on the libavutil side
#   --disable-vulkan         no Vulkan hwaccel
#   --disable-bzlib/lzma     drop bzip2 / xz codec deps
#   --disable-iconv          skip libiconv (not needed for our containers)
#   --disable-sdl2           we use SDL3 separately; FFmpeg's SDL is for ffplay
#   --disable-alsa           no ALSA dep (PulseAudio/JACK aren't enabled by
#                            default in 8.1, so no separate flag needed)
#   --enable-pic             required for shared lib output
#   --enable-shared / --disable-static
#                            output .so only; static .a not P/Invokable from .NET
#   --extra-ldflags=-Wl,-Bsymbolic
#                            prefer in-library symbol resolution; reduces risk
#                            that an LD_PRELOAD or unrelated .so on the
#                            host/runtime intercepts FFmpeg-internal calls.
#   --cpu=x86-64-v2          pin the baseline ISA to match .NET 10's documented
#                            x64 minimum (CX16, POPCNT, SSE3, SSSE3, SSE4.1,
#                            SSE4.2 - i.e. Intel Sandy Bridge 2011 / AMD
#                            Bulldozer 2011 and newer). FFmpeg keeps its
#                            runtime SIMD dispatch on top, so AVX/AVX2/AVX-512
#                            paths still get selected on capable CPUs - this
#                            flag only constrains the non-dispatched scalar
#                            code so it cannot drift above what .NET 10 itself
#                            guarantees, and it stops a build host's
#                            CFLAGS=-march=native from accidentally specializing
#                            the shipped libs to the build machine.
#
# zlib intentionally LEFT enabled (default): several muxers/demuxers (mov,
# matroska) need it for compressed metadata; build-time autodetect picks up
# the host's zlib1g-dev. zlib is universally present on every modern Linux
# target, so this is not a portability concern.
#
# Flags that exist in older FFmpeg trees but NOT in 8.1 (and therefore
# omitted): --disable-postproc (postproc has no separate disable flag in
# 8.1, the library is opt-in via --enable-postproc), --disable-libxcb /
# --disable-pulse / --disable-jack (these only have --enable-* forms in
# 8.1; defaults are off, plus avdevice is disabled).

# The flag list itself is defined near the top of this script (see
# FFMPEG_CONFIGURE_FLAGS) so that --print-stamp can hash it without touching
# the source tree; only --prefix, which is a build-tree path, is added here.
#
# NOTE: DT_RUNPATH=$ORIGIN is NOT injected via --extra-ldsoflags -
# see the post-install `patchelf` step below for the rationale. Briefly:
# passing -Wl,-rpath,'$ORIGIN' through bash -> FFmpeg's configure (sh) ->
# config.mak -> make -> recipe shell requires 3 layers of $-escaping to
# survive both sh's $$ -> PID substitution and make's $$ -> $ rule, and
# the FFmpeg release we build against has historically broken at least
# one of those layers (we observed the literal PID "260291ORIGIN"
# landing in DT_RUNPATH on FFmpeg 8.1). Doing it as a post-build
# patchelf rewrite sidesteps the whole escaping minefield.

CONFIGURE_FLAGS=(--prefix="$STAGE_DIR" "${FFMPEG_CONFIGURE_FLAGS[@]}")

# Skip reconfigure if the cached _build/ already has a matching config.h and
# the configure flags haven't changed (cached in _build/.configure_flags).
FLAGS_FILE="$FFMPEG_BUILD_DIR/.configure_flags"
FLAGS_HASH="$(printf '%s\n' "src=$FFMPEG_SRC_DIR" "${CONFIGURE_FLAGS[@]}" | sha256sum | awk '{print $1}')"
NEED_CONFIGURE=1
if [ -f "$FFMPEG_BUILD_DIR/config.h" ] && [ -f "$FLAGS_FILE" ]; then
    if [ "$(cat "$FLAGS_FILE")" = "$FLAGS_HASH" ]; then
        NEED_CONFIGURE=0
    fi
fi

if [ "$NEED_CONFIGURE" = "1" ]; then
    echo "==> Configuring FFmpeg $FFMPEG_VERSION (out-of-source build at $FFMPEG_BUILD_DIR)"
    (
        cd "$FFMPEG_BUILD_DIR"
        "$FFMPEG_SRC_DIR/configure" "${CONFIGURE_FLAGS[@]}"
    )
    printf '%s\n' "$FLAGS_HASH" > "$FLAGS_FILE"
else
    echo "==> Reusing cached configure ($FFMPEG_BUILD_DIR/config.h)"
fi

# ---- build & install --------------------------------------------------------

echo "==> Building FFmpeg with -j$JOBS"
make -C "$FFMPEG_BUILD_DIR" -j"$JOBS"

echo "==> Installing into $STAGE_DIR"
make -C "$FFMPEG_BUILD_DIR" install >/dev/null

# ---- sanity check the build outputs ----------------------------------------
# Refuse to ship anything if the SOVERSIONs don't match what FFmpeg.AutoGen
# 8.1 expects (LibraryVersionMap in MySdlAudioInterop.cs). A mismatch here
# means an upstream version bump that needs the version map updated too -
# silently shipping the wrong SOVERSION would manifest as
# DllNotFoundException at runtime instead of failing here.

declare -A EXPECTED_SOVER=(
    [avcodec]=62
    [avformat]=62
    [avutil]=60
    [swresample]=6
    [swscale]=9
)

LIB_SRC="$STAGE_DIR/lib"
[ -d "$LIB_SRC" ] || { echo "ERROR: $LIB_SRC missing after install" >&2; exit 1; }

for name in "${!EXPECTED_SOVER[@]}"; do
    sover="${EXPECTED_SOVER[$name]}"
    f="$LIB_SRC/lib${name}.so.${sover}"
    if [ ! -e "$f" ]; then
        echo "ERROR: expected lib not built: $f" >&2
        echo "Hint: SOVERSION may have shifted. Update the EXPECTED_SOVER table" >&2
        echo "      in this script and the LibraryVersionMap in Pulsar's" >&2
        echo "      ClientPlugin/Audio/MySdlAudioInterop.cs together." >&2
        exit 1
    fi
done

# ---- patch DT_RUNPATH=$ORIGIN onto each produced .so -----------------------
# This is what makes the FFmpeg libs self-locating once they ship inside a
# consumer's Bin/ folder alongside its apphost. Without it, the inter-FFmpeg
# NEEDED entries (libavformat -> libavcodec.so.62 -> libavutil.so.60 /
# libswresample.so.6, etc.) are resolved by glibc's default search path,
# which does NOT include the executable's own directory - so they would
# either miss entirely or, worse, silently bind to a different-ABI FFmpeg
# version from the host's /etc/ld.so.cache. With DT_RUNPATH=$ORIGIN burned
# in, ld.so locates each FFmpeg lib's siblings via the loaded lib's own
# directory, and the consumer's launcher does not need to prepend Bin/ to
# LD_LIBRARY_PATH.
#
# Why patchelf instead of -Wl,-rpath,$ORIGIN via configure: passing the
# literal token "$ORIGIN" through bash -> FFmpeg's configure (sh) ->
# config.mak -> make -> recipe shell requires three layers of $-escaping
# that have to thread through both sh's "$$ -> PID" substitution and
# make's "$$ -> $" rule. We've observed at least one of those layers
# breaking on FFmpeg 8.1 (the literal PID landed in DT_RUNPATH, e.g.
# "260291ORIGIN"). patchelf rewrites the .dynamic section after the link
# is complete and is therefore immune to all the upstream escaping
# variability.
echo "==> Patching DT_RUNPATH=\$ORIGIN onto FFmpeg libs"
for name in "${!EXPECTED_SOVER[@]}"; do
    sover="${EXPECTED_SOVER[$name]}"
    f="$LIB_SRC/lib${name}.so.${sover}"
    patchelf --set-rpath '$ORIGIN' "$f"
done

# Verify the .so files don't depend on anything beyond glibc / vdso / loader.
# Anything else (e.g. libpulse, libdrm, libx264) means a configure flag leaked
# through and the bundle would silently require that lib at runtime.
echo "==> Verifying minimal runtime dependencies"
ALLOWED_RE='^(linux-vdso|ld-linux|libc|libm|libpthread|libdl|librt|libgcc_s|libstdc\+\+|libz|libav(codec|format|util)|libsw(resample|scale))(-[a-z0-9_-]+)?\.so'
DEP_LEAK=0
for name in "${!EXPECTED_SOVER[@]}"; do
    sover="${EXPECTED_SOVER[$name]}"
    f="$LIB_SRC/lib${name}.so.${sover}"
    while IFS= read -r line; do
        # ldd line: "  libfoo.so.1 => /path (0x...)" or "  /lib64/ld-linux..."
        # Extract bare lib name (col 1 after trim).
        bare="$(printf '%s' "$line" | awk '{print $1}')"
        # Strip the path-only (no =>) entries down to basename.
        bare="${bare##*/}"
        [ -z "$bare" ] && continue
        if ! [[ "$bare" =~ $ALLOWED_RE ]]; then
            echo "  $name: unexpected dep $bare" >&2
            DEP_LEAK=1
        fi
    done < <(ldd "$f" | sed 's/^[[:space:]]*//')
done
if [ "$DEP_LEAK" = "1" ]; then
    echo "ERROR: at least one FFmpeg lib has an unexpected runtime dep." >&2
    echo "Re-check the configure flags - we want only glibc + libz." >&2
    exit 1
fi

# Verify the literal token "$ORIGIN" actually landed in DT_RUNPATH on every
# FFmpeg lib. If the patchelf step above is ever broken (e.g. swapped to a
# patchelf build with a regression, accidentally removed, or invoked on the
# wrong file), this assertion fails loudly here rather than letting us ship
# libs that silently need LD_LIBRARY_PATH again.
echo "==> Verifying DT_RUNPATH=\$ORIGIN on built libs"
RUNPATH_MISSING=0
for name in "${!EXPECTED_SOVER[@]}"; do
    sover="${EXPECTED_SOVER[$name]}"
    f="$LIB_SRC/lib${name}.so.${sover}"
    runpath="$(readelf -d "$f" 2>/dev/null | awk '/\(RUNPATH\)/ {match($0, /\[.*\]/); print substr($0, RSTART+1, RLENGTH-2)}')"
    if [ "$runpath" != '$ORIGIN' ]; then
        echo "  lib${name}.so.${sover}: expected DT_RUNPATH='\$ORIGIN', got '${runpath}'" >&2
        RUNPATH_MISSING=1
    fi
done
if [ "$RUNPATH_MISSING" = "1" ]; then
    echo "ERROR: at least one FFmpeg lib is missing DT_RUNPATH=\$ORIGIN." >&2
    echo "Re-check the --extra-ldsoflags escaping in CONFIGURE_FLAGS." >&2
    exit 1
fi

# ---- copy into the Libraries folder -------------------------------------------
# Wipe the previously staged FFmpeg files first. Without this, bumping
# FFMPEG_VERSION on an existing build/ tree leaves the old fully-versioned
# libraries behind AND leaves libavcodec.so / libavcodec.so.62 pointing at
# them, so the archive would ship two FFmpeg builds with the unversioned
# aliases resolving to the stale one. Only FFmpeg's own names are removed --
# the sibling build scripts and build.sh populate this same directory.

echo "==> Clearing previously staged FFmpeg libs from $LIBRARIES_DIR"
find "$LIBRARIES_DIR" -maxdepth 1 \
     \( -name 'libav*.so*' -o -name 'libsw*.so*' \) -delete

echo "==> Staging outputs into $LIBRARIES_DIR"
# The archives carry no symlinks and no version-suffixed filenames: each
# library ships as a single real file under its bare name (libavcodec.so).
# The SONAMEs inside the binaries stay as upstream produced them, but the
# cross-FFmpeg NEEDED entries are rewritten below to the bare names so
# DT_RUNPATH=$ORIGIN keeps resolving siblings next to the loaded library.
for name in "${!EXPECTED_SOVER[@]}"; do
    sover="${EXPECTED_SOVER[$name]}"
    install -m 0755 "$LIB_SRC/lib${name}.so.${sover}" "$LIBRARIES_DIR/lib${name}.so"
done

echo "==> Rewriting cross-FFmpeg NEEDED entries to the bare names"
for name in "${!EXPECTED_SOVER[@]}"; do
    f="$LIBRARIES_DIR/lib${name}.so"
    for dep in "${!EXPECTED_SOVER[@]}"; do
        # No-op when the entry is absent; only actual references are renamed.
        patchelf --replace-needed \
            "lib${dep}.so.${EXPECTED_SOVER[$dep]}" "lib${dep}.so" "$f"
    done
done

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

echo
echo "==> Staged FFmpeg libs into $LIBRARIES_DIR:"
# List only the files this script actually touched (the FFmpeg sonames +
# their symlink aliases). The build/Libraries/ staging folder also contains
# non-FFmpeg deps (DXVK, Steamworks.NET.dll, and the EOS / Steam vendor
# blobs) populated by the sibling build_*.sh scripts or copied from
# Vendor/ by ../build.sh, so it would be misleading to list them here
# under "Staged".
( cd "$LIBRARIES_DIR" && ls -1 libav*.so* libsw*.so* )
