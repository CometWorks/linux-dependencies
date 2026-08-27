#!/usr/bin/env bash
# build_steamworks_net.sh
#
# Builds Steamworks.NET.dll from upstream sources at
# https://github.com/rlabrecque/Steamworks.NET and installs it into the
# build/Libraries-Steam staging folder, from which the steam-dependencies
# archive is packaged (Steam bits ship separately from the SE1/SE2 archives).
#
# We pin to a specific commit SHA (not a tag) because rlabrecque tags
# correspond to Steamworks SDK versions while the .dll Pulsar and Magnetar
# consumed historically was built straight from a HEAD commit — the
# AssemblyInformationalVersion of that previously committed
# Steamworks.NET.dll embeds the exact SHA, which is the value pinned below.
#
# The repo's Standalone3.0/Steamworks.NET.csproj targets net8.0 and matches
# the assembly both consumers use; built with `dotnet build -c Release` it
# produces an MIT-licensed Steamworks.NET.dll in bin/Release/net8.0/.
#
# Source layout (under the gitignored build/ folder of this repo):
#
#   build/
#   ├── Libraries-Steam/          Steam staging dir this script populates
#   ├── Steamworks.NET/           clone of rlabrecque/Steamworks.NET (cached)
#   └── steamworks-net.stamp      last-built commit SHA (cache key)
#
# Usage:
#   ./build_steamworks_net.sh           Build (or no-op if cached).
#   ./build_steamworks_net.sh --clean   Wipe build outputs and rebuild.
#   ./build_steamworks_net.sh --print-stamp
#                                       Print this build's cache stamp and exit
#                                       without touching the network. The value
#                                       is the content key CI caches the staged
#                                       libraries under; see docs/building.md.
#
# Env-var overrides (defaults shown):
#   STEAMWORKS_NET_REPO   = https://github.com/rlabrecque/Steamworks.NET.git
#   STEAMWORKS_NET_COMMIT = 68e72a49caf03a07722d4d4b471bbc7c0785f80b
#                           (commit baked into the previously committed
#                            Libraries/Steamworks.NET.dll's
#                            AssemblyInformationalVersion)
#   BUILD_DIR             = <repo>/build
#   LIBRARIES_STEAM_DIR   = $BUILD_DIR/Libraries-Steam
#
# Requirements: git, dotnet SDK (with net8.0 targeting pack).

set -euo pipefail

STEAMWORKS_NET_REPO="${STEAMWORKS_NET_REPO:-https://github.com/rlabrecque/Steamworks.NET.git}"
STEAMWORKS_NET_COMMIT="${STEAMWORKS_NET_COMMIT:-68e72a49caf03a07722d4d4b471bbc7c0785f80b}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR_DEFAULT="$REPO_DIR/build"

BUILD_DIR="${BUILD_DIR:-$BUILD_DIR_DEFAULT}"
LIBRARIES_STEAM_DIR="${LIBRARIES_STEAM_DIR:-$BUILD_DIR/Libraries-Steam}"

CLONE_DIR="$BUILD_DIR/Steamworks.NET"
CSPROJ="$CLONE_DIR/Standalone3.0/Steamworks.NET.csproj"
STAMP_FILE="$BUILD_DIR/steamworks-net.stamp"
STAMP_CONTENT="$STEAMWORKS_NET_COMMIT"
DLL_NAME="Steamworks.NET.dll"

CLEAN=0
PRINT_STAMP=0
for arg in "$@"; do
    case "$arg" in
        --clean)       CLEAN=1 ;;
        --print-stamp) PRINT_STAMP=1 ;;
        -h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$PRINT_STAMP" = "1" ]; then
    printf '%s\n' "$STAMP_CONTENT"
    exit 0
fi

# ---- preflight --------------------------------------------------------------

for tool in git dotnet; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: required tool not found in PATH: $tool" >&2
        exit 1
    }
done

mkdir -p "$BUILD_DIR" "$LIBRARIES_STEAM_DIR"

# ---- cache check ------------------------------------------------------------

if [ "$CLEAN" = "1" ]; then
    rm -rf "$CLONE_DIR/Standalone3.0/bin" "$CLONE_DIR/Standalone3.0/obj"
elif [ -f "$LIBRARIES_STEAM_DIR/$DLL_NAME" ] \
   && [ -f "$STAMP_FILE" ] \
   && [ "$(cat "$STAMP_FILE")" = "$STAMP_CONTENT" ]; then
    echo "==> Cached build matches commit $STEAMWORKS_NET_COMMIT; skipping rebuild"
    echo "==> $DLL_NAME already in $LIBRARIES_STEAM_DIR"
    exit 0
fi

# ---- clone / fetch ----------------------------------------------------------

if [ ! -d "$CLONE_DIR/.git" ]; then
    echo "==> Cloning $STEAMWORKS_NET_REPO -> $CLONE_DIR"
    rm -rf "$CLONE_DIR"
    git clone "$STEAMWORKS_NET_REPO" "$CLONE_DIR"
else
    echo "==> Fetching origin in $CLONE_DIR"
    git -C "$CLONE_DIR" fetch origin --tags --prune
fi

# The pinned commit lives on a PR ref (PR #738, "Upgrade Steamworks SDK to
# v1.64"), which a default clone/fetch does NOT pull. Try a plain checkout
# first (cheap), and on failure fetch PR refs and retry. GitHub exposes PR
# heads under refs/pull/<n>/head; mirroring them locally as
# refs/remotes/origin/pr/<n> keeps the fallback self-contained.
echo "==> Pinning to commit $STEAMWORKS_NET_COMMIT"
if ! git -C "$CLONE_DIR" -c advice.detachedHead=false \
        checkout "$STEAMWORKS_NET_COMMIT" 2>/dev/null; then
    echo "==> Commit not reachable from any branch/tag; fetching PR refs"
    git -C "$CLONE_DIR" fetch origin \
        "+refs/pull/*/head:refs/remotes/origin/pr/*"
    git -C "$CLONE_DIR" -c advice.detachedHead=false \
        checkout "$STEAMWORKS_NET_COMMIT"
fi

# ---- build ------------------------------------------------------------------

[ -f "$CSPROJ" ] || {
    echo "ERROR: missing csproj at $CSPROJ" >&2
    echo "       The pinned commit may pre-date Standalone3.0/. Update" >&2
    echo "       STEAMWORKS_NET_COMMIT or switch to the Standalone/ project." >&2
    exit 1
}

echo "==> dotnet build $CSPROJ (Release)"
dotnet build -c Release -v minimal "$CSPROJ"

# The csproj sets <TargetFramework>net8.0</TargetFramework>; outputs land in
# Standalone3.0/bin/Release/net8.0/. `find` the dll rather than hard-coding
# the path so a future TFM bump still works.

# `|| true` so a missing bin/Release/ reaches the friendly error below instead
# of aborting on find's own "No such file or directory" via set -e.
DLL_SRC="$(find "$CLONE_DIR/Standalone3.0/bin/Release" -type f -name "$DLL_NAME" -print -quit 2>/dev/null || true)"
if [ -z "$DLL_SRC" ]; then
    echo "ERROR: dotnet build did not produce $DLL_NAME under $CLONE_DIR/Standalone3.0/bin/Release" >&2
    exit 1
fi

echo "==> Staging $DLL_NAME into $LIBRARIES_STEAM_DIR"
install -m 0644 "$DLL_SRC" "$LIBRARIES_STEAM_DIR/$DLL_NAME"

printf '%s\n' "$STAMP_CONTENT" > "$STAMP_FILE"

echo
echo "==> Staged $DLL_NAME into $LIBRARIES_STEAM_DIR:"
ls -l "$LIBRARIES_STEAM_DIR/$DLL_NAME"
