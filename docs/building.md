# Building locally

You do not need to build this repo to consume it — Pulsar and Magnetar
download the published release archive. Build locally when you are changing a
dependency version, debugging a build failure, or testing a change before
opening a pull request.

## Prerequisites

On Debian / Ubuntu:

```bash
sudo apt install build-essential pkg-config make cmake curl tar git nasm patchelf binutils zlib1g-dev meson ninja-build glslang-tools libvulkan-dev libpulse-dev libasound2-dev libpipewire-0.3-dev
```

You also need the **.NET SDK** (8.0 or newer, with the `net8.0` targeting pack)
for the Steamworks.NET build. Install it from
<https://dotnet.microsoft.com/download> or your distribution's packages.

What each group is for:

| Tools | Needed by |
| --- | --- |
| `build-essential`, `pkg-config`, `make`, `nasm`, `zlib1g-dev` | FFmpeg (`nasm` provides the x86 SIMD assembler; `yasm` also works) |
| `meson`, `ninja-build`, `glslang-tools`, `libvulkan-dev` | DXVK Native |
| `cmake` | the pinned SDL3 that DXVK compiles against, and OpenAL Soft |
| `libpulse-dev`, `libasound2-dev`, `libpipewire-0.3-dev` | OpenAL's audio backends — see below |
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

Builds every dependency, stages `build/Libraries/` (SE1) and
`build/Libraries-SE2/` (SE2), verifies the staged trees, and packages
`dist/linux-dependencies.tar.gz` plus — once the FMOD blobs are committed
under `Vendor/se2/` — `dist/linux-dependencies-se2.tar.gz`. Until then the
SE2 archive is skipped with a warning; see
[Vendor/se2/README.md](../Vendor/se2/README.md).

A cold first run takes roughly 10–20 minutes, dominated by FFmpeg and DXVK.
Subsequent runs are near-instant when nothing changed — see
[Caching](#caching).

### Options

| Option | Effect |
| --- | --- |
| `--clean` | Passes `--clean` to every sub-build: wipes cached source and build trees and rebuilds from scratch |
| `--no-package` | Stages `build/Libraries/` but skips the tarball |
| `--only=ffmpeg,dxvk` | Runs only the listed sub-builds. Valid names: `ffmpeg`, `dxvk`, `dxvk-se2`, `openal`, `steamworks-net`. An unknown name is rejected rather than silently skipping everything |
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
| `LIBRARIES_SE2_DIR` | `$BUILD_DIR/Libraries-SE2` |
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
| DXVK (SE1) | `build/dxvk/` (clone), `build/dxvk.stamp` | A changed `DXVK_VERSION` |
| DXVK (SE2) | `build/dxvk-se2/` (clone), `build/dxvk-se2.stamp` | A changed `DXVK_VERSION` **or** any change to the `Patches/dxvk/*.patch` series (its SHA-256 is part of the stamp) |
| SDL3 | `build/SDL/` (clone), `build/sdl3-prefix/`, `build/sdl3.stamp` | A changed `SDL3_VERSION` |
| OpenAL | `build/openal-soft-1.25.2.tar.bz2`, `build/openal-soft-1.25.2/`, `build/openal.stamp` | A changed `OPENAL_VERSION` |
| Steamworks.NET | `build/Steamworks.NET/` (clone), `build/steamworks-net.stamp` | A changed `STEAMWORKS_NET_COMMIT` |

SDL3 is built only when DXVK actually rebuilds — it is a build-time-only
dependency for DXVK's headers and is never shipped. See
[dependencies.md](dependencies.md#sdl3-is-a-build-time-dependency).

To force specific work:

```bash
rm build/dxvk.stamp                # rebuild DXVK (SE1) only
rm build/dxvk-se2.stamp            # rebuild DXVK (SE2) only
rm -rf build/ffmpeg-8.1            # re-extract and reconfigure FFmpeg
rm build/ffmpeg-8.1.tar.xz         # re-download the FFmpeg tarball
./build.sh --clean                 # rebuild everything from scratch
```

## Output

After a successful run:

```
build/Libraries/                       staged SE1 tree (what the SE1 archive mirrors)
build/Libraries-SE2/                   staged SE2 tree
dist/linux-dependencies.tar.gz         the SE1 release archive
dist/linux-dependencies-se2.tar.gz     the SE2 release archive (only with the
                                       FMOD blobs committed under Vendor/se2/)
```

All of it is gitignored. See [release-archive.md](release-archive.md) for the
exact contents and the guarantees consumers rely on.

## Troubleshooting

**`ERROR: required tool not found in PATH: <tool>`** — install it; the table
above says which dependency needs it.

**`ERROR: expected lib not built: libavcodec.so.62`** — FFmpeg's SOVERSION
moved, which means the pinned version changed or upstream bumped it. See
[maintenance.md](maintenance.md); the `EXPECTED_SOVER` table and Pulsar's
`LibraryVersionMap` have to move together.

**OpenAL: `Required backend not found`** — a backend's development headers are
missing. Install `libpulse-dev`, `libasound2-dev` and `libpipewire-0.3-dev`.
This failure is deliberate: without it the build would quietly produce an
OpenAL with no audio backends.

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

**`WARNING: FMOD vendor blobs not found under Vendor/se2/`** — expected until
the FMOD runtime is committed there; the SE2 archive is skipped and the SE1
build is unaffected. To produce the SE2 archive, follow
[Vendor/se2/README.md](../Vendor/se2/README.md).

**`ERROR: patch failed to apply:`** — a patch under `Patches/dxvk/` no longer
applies to the pinned DXVK version, usually after a `DXVK_VERSION` bump.
Rebase the series; see [maintenance.md](maintenance.md#bumping-dxvk).
