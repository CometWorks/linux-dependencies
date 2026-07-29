# Building locally

You do not need to build this repo to consume it — Pulsar and Magnetar
download the published release archive. Build locally when you are changing a
dependency version, debugging a build failure, or testing a change before
opening a pull request.

## Prerequisites

On Debian / Ubuntu:

```bash
sudo apt install build-essential pkg-config make curl tar git nasm patchelf binutils zlib1g-dev meson ninja-build glslang-tools libvulkan-dev
```

You also need the **.NET SDK** (8.0 or newer, with the `net8.0` targeting pack)
for the Steamworks.NET build. Install it from
<https://dotnet.microsoft.com/download> or your distribution's packages.

What each group is for:

| Tools | Needed by |
| --- | --- |
| `build-essential`, `pkg-config`, `make`, `nasm`, `zlib1g-dev` | FFmpeg (`nasm` provides the x86 SIMD assembler; `yasm` also works) |
| `meson`, `ninja-build`, `glslang-tools`, `libvulkan-dev` | DXVK Native |
| `patchelf`, `binutils` | `DT_RUNPATH=$ORIGIN` patching and the `readelf` verification |
| `curl`, `tar`, `git` | Fetching sources |
| .NET SDK | Steamworks.NET |

Each script preflights its own tools and aborts with a clear message naming the
missing one, so you can also just run `./build.sh` and install what it asks
for.

## Usage

```bash
./build.sh
```

Builds every dependency, stages `build/Libraries/`, verifies the staged tree,
and packages `dist/linux-dependencies.tar.gz`.

A cold first run takes roughly 10–20 minutes, dominated by FFmpeg and DXVK.
Subsequent runs are near-instant when nothing changed — see
[Caching](#caching).

### Options

| Option | Effect |
| --- | --- |
| `--clean` | Passes `--clean` to every sub-build: wipes cached source and build trees and rebuilds from scratch |
| `--no-package` | Stages `build/Libraries/` but skips the tarball |
| `--only=ffmpeg,dxvk` | Runs only the listed sub-builds. Valid names: `ffmpeg`, `dxvk`, `steamworks-net` |
| `--skip=dxvk` | Runs every sub-build except the listed ones |
| `-h`, `--help` | Prints the header comment |

The vendor blob and licence copies always run, regardless of `--only` /
`--skip`.

With `--only` or `--skip` the staged tree is incomplete by definition, so the
final assertion reports what is missing but treats it as expected, and
packaging is skipped.

### Environment overrides

| Variable | Default |
| --- | --- |
| `REPO_DIR` | directory containing `build.sh` |
| `BUILD_DIR` | `$REPO_DIR/build` |
| `LIBRARIES_DIR` | `$BUILD_DIR/Libraries` |
| `OUTPUT_DIR` | `$REPO_DIR/dist` |
| `VENDOR_DIR` | `$REPO_DIR/Vendor` |
| `LICENSES_SRC` | `$REPO_DIR/Licenses` |
| `JOBS` | `$(nproc)` |

Per-dependency overrides (`FFMPEG_VERSION`, `DXVK_VERSION`,
`STEAMWORKS_NET_COMMIT`, …) are documented in the header comment of each script
under `Scripts/`.

### Running a single dependency build

The scripts under `Scripts/` are standalone and can be run directly:

```bash
./Scripts/build_ffmpeg.sh --clean
```

They stage into the same `build/Libraries/` folder. This is usually the fastest
way to iterate on one dependency.

## Caching

Everything under `build/` is a gitignored cache, keyed so that an unchanged
rerun does no work:

| Dependency | Cache | Invalidated by |
| --- | --- | --- |
| FFmpeg | `build/ffmpeg-8.1.tar.xz` (download), `build/ffmpeg-8.1/` (source), `build/ffmpeg-8.1/_build/` (objects) | A changed `configure` flag set, tracked by a hash in `_build/.configure_flags`; otherwise an incremental `make` |
| DXVK | `build/dxvk/` (clone), `build/dxvk.stamp` | A changed `DXVK_VERSION` |
| Steamworks.NET | `build/Steamworks.NET/` (clone), `build/steamworks-net.stamp` | A changed `STEAMWORKS_NET_COMMIT` |

To force specific work:

```bash
rm build/dxvk.stamp                # rebuild DXVK only
rm -rf build/ffmpeg-8.1            # re-extract and reconfigure FFmpeg
rm build/ffmpeg-8.1.tar.xz         # re-download the FFmpeg tarball
./build.sh --clean                 # rebuild everything from scratch
```

## Output

After a successful run:

```
build/Libraries/           staged tree (what the archive mirrors)
dist/linux-dependencies.tar.gz   the release archive
```

Both directories are gitignored. See
[release-archive.md](release-archive.md) for the exact contents and the
guarantees consumers rely on.

## Troubleshooting

**`ERROR: required tool not found in PATH: <tool>`** — install it; the table
above says which dependency needs it.

**`ERROR: expected lib not built: libavcodec.so.62`** — FFmpeg's SOVERSION
moved, which means the pinned version changed or upstream bumped it. See
[maintenance.md](maintenance.md); the `EXPECTED_SOVER` table and Pulsar's
`LibraryVersionMap` have to move together.

**`<name>: unexpected dep <lib>`** — an FFmpeg configure flag stopped
suppressing something and the library now depends on a host package. Do not
just widen the allow-list: find the flag that regressed, because that
dependency will be missing on users' machines.

**`expected DT_RUNPATH='$ORIGIN', got ''`** — the `patchelf` step did not take
effect. Check that `patchelf` is a working build and is being invoked on the
real versioned file, not a symlink.

**`ERROR: dependency staging is incomplete.`** — a sub-build succeeded but did
not produce everything `build.sh` expects. The lines above it name each missing
file.

**`ERROR: missing vendor blob:`** — `Vendor/libEOSSDK-Linux-Shipping.so` or
`Vendor/libsteam_api.so` is absent. These are committed; a fresh clone has
them, so this usually means a partial checkout.
