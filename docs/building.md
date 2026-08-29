# Building locally

You do not need to build this repo to consume it — Pulsar and Magnetar
download the published release archive. Build locally when you are changing a
dependency version, debugging a build failure, or testing a change before
opening a pull request.

## Prerequisites

On Debian / Ubuntu:

```bash
sudo apt install build-essential pkg-config make cmake python3 curl tar git nasm patchelf binutils zlib1g-dev meson ninja-build glslang-tools libvulkan-dev mingw-w64-tools libpulse-dev libasound2-dev libpipewire-0.3-dev libx11-dev libxext-dev libxcursor-dev libxi-dev libxfixes-dev libxrandr-dev libxrender-dev libxss-dev libxtst-dev libwayland-dev wayland-protocols libdecor-0-dev libxkbcommon-dev libegl-dev libdrm-dev libgbm-dev
```

You also need the **.NET SDK** (8.0 or newer, with the `net8.0` targeting pack)
for the Steamworks.NET build. Install it from
<https://dotnet.microsoft.com/download> or your distribution's packages.

What each group is for:

| Tools | Needed by |
| --- | --- |
| `build-essential`, `pkg-config`, `make`, `nasm`, `zlib1g-dev` | FFmpeg (`nasm` provides the x86 SIMD assembler; `yasm` also works) |
| `meson`, `ninja-build`, `glslang-tools`, `libvulkan-dev` | DXVK Native and vkd3d-proton |
| `mingw-w64-tools` | `widl`, the Wine IDL compiler vkd3d-proton generates its COM headers with (`wine64-tools` works too; the build script shims whichever name is found) |
| `cmake` (>= 3.20) | the pinned SDL3 that DXVK compiles against and that we ship, OpenAL Soft, and the DirectX Shader Compiler |
| `ninja-build`, `python3`, `cmake` | the DirectX Shader Compiler, and the second stock DXC build the FidelityFX shader compiler runs against |
| `libx11-dev`, `libxext-dev`, `libxcursor-dev`, `libxi-dev`, `libxfixes-dev`, `libxrandr-dev`, `libxrender-dev`, `libxss-dev`, `libxtst-dev` | SDL3's X11 video driver — see below |
| `libwayland-dev`, `wayland-protocols`, `libdecor-0-dev`, `libxkbcommon-dev`, `libegl-dev`, `libdrm-dev`, `libgbm-dev` | SDL3's Wayland and KMSDRM video drivers — see below |
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

Builds every dependency once, stages `build/Libraries/` (SE1),
`build/Libraries-SE2/` (SE2) and `build/Libraries-Steam/` (Steam), verifies
the staged trees, and packages `dist/se1-dependencies.tar.gz`,
`dist/se2-dependencies.tar.gz` and `dist/steam-dependencies.tar.gz`. The
patched DXVK binaries are copied into the SE2 tree rather than rebuilt.

A cold first run is roughly half an hour on four cores, dominated by the
DirectX Shader Compiler — about 19 minutes of it, more than everything else
combined. Without DXC the rest of the pipeline is 10–12 minutes, so
`--skip=dxc` is worth remembering while iterating on another dependency.
Subsequent runs are near-instant when nothing changed — see
[Caching](#caching).

Peak disk use is around 550 MB for the DXC clone and its build tree; the
build tree is deleted once its library is staged.

### Options

| Option | Effect |
| --- | --- |
| `--clean` | Passes `--clean` to every sub-build: wipes cached source and build trees and rebuilds from scratch |
| `--no-package` | Stages `build/Libraries/` but skips the tarball |
| `--only=ffmpeg,dxvk` | Runs only the listed sub-builds. Valid names: `ffmpeg`, `sdl3`, `dxvk`, `vkd3d-proton`, `dxc`, `fidelityfx`, `openal`, `steamworks-net`. An unknown name is rejected rather than silently skipping everything |
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
| `LIBRARIES_STEAM_DIR` | `$BUILD_DIR/Libraries-Steam` |
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

They stage into the same `build/Libraries/` folder (`build_vkd3d_proton.sh`,
`build_dxc.sh` and `build_fidelityfx.sh` into `build/Libraries-SE2/`,
`build_steamworks_net.sh`
into `build/Libraries-Steam/`, and `build_sdl3.sh` into both game trees,
matching the archive each ships in). This is usually the fastest way to
iterate on one dependency.

`build_dxc.sh` accepts `DXC_KEEP_BUILD_TREE=1`, which keeps its cmake build
tree instead of deleting it after staging. Set it whenever you expect to
rebuild — otherwise every run starts from an empty build tree and pays the
full DXC build.

`build_fidelityfx.sh` needs vkd3d-proton's installed headers and invokes
`build_vkd3d_proton.sh` itself if they are missing, so running it on its own
works from a cold tree. It also keeps its own stock DXC build under
`build/dxc-host/` — a second full DXC build, cached separately from the
FidelityFX stamp so that editing the patch series does not pay for it twice.

## Caching

Everything under `build/` is a gitignored cache, keyed so that an unchanged
rerun does no work:

| Dependency | Cache | Invalidated by |
| --- | --- | --- |
| FFmpeg | `build/ffmpeg-8.1.tar.xz` (download), `build/ffmpeg-8.1/` (source), `build/ffmpeg-8.1/_build/` (objects), `build/ffmpeg.stamp` | A changed `FFMPEG_VERSION` **or** any change to `FFMPEG_CONFIGURE_FLAGS` (its SHA-256 is part of the stamp). Within a rebuild, `_build/.configure_flags` decides whether `configure` re-runs; otherwise it is an incremental `make` |
| DXVK | `build/dxvk/` (clone), `build/dxvk.stamp` | A changed `DXVK_VERSION` **or** any change to the `Patches/dxvk/*.patch` series (its SHA-256 is part of the stamp) |
| vkd3d-proton | `build/vkd3d-proton/` (clone), `build/vkd3d-proton-out/` (install destdir, whose headers the FidelityFX build compiles against), `build/vkd3d-proton.stamp` | A changed `VKD3D_PROTON_COMMIT`, any change to the `Patches/vkd3d-proton/*.patch` series, **or** a bumped `ARTEFACT_REV` in `build_vkd3d_proton.sh` (which set of outputs the build produces is part of the stamp) |
| SDL3 | `build/SDL/` (clone), `build/sdl3-prefix/`, `build/sdl3.stamp` | A changed `SDL3_VERSION`, or a bumped `CONFIG_REV` in `build_sdl3.sh` (its cmake options are part of the stamp) |
| OpenAL | `build/openal-soft-1.25.2.tar.bz2`, `build/openal-soft-1.25.2/`, `build/openal.stamp` | A changed `OPENAL_VERSION` |
| Steamworks.NET | `build/Steamworks.NET/` (clone), `build/steamworks-net.stamp` | A changed `STEAMWORKS_NET_COMMIT` |
| DXC | `build/dxc/` (clone), `build/dxc.stamp` | A changed `DXC_COMMIT` **or** any change to the `Patches/dxc/*.patch` series |
| FidelityFX | `build/fidelityfx/` and `build/ffx-sc-src/` (clones), `build/fidelityfx.stamp` | A changed `FIDELITYFX_COMMIT` or `FFX_SC_COMMIT`, the `DXC_COMMIT` read out of `build_dxc.sh`, **or** any change to the `Patches/fidelityfx/*/*.patch` series |
| FidelityFX's host DXC | `build/dxc-host/` (clone + build tree), `build/dxc-host.stamp` | A changed `DXC_COMMIT`. Deliberately separate from the FidelityFX stamp: editing the FidelityFX patches must not trigger another full DXC build |

Only SDL3's *build* is cached; its staging step runs every time, so a wiped
`build/Libraries*/` is repopulated without a rebuild. `build_dxvk.sh` also
invokes `build_sdl3.sh` itself (it needs the headers), which is a no-op when
the top-level `sdl3` step already ran. See
[dependencies.md](dependencies.md#sdl3-3412).

Every script prints its own stamp on demand and exits without touching the
network or the build tree:

```bash
./Scripts/build_dxc.sh --print-stamp
```

That value is the whole cache identity of a dependency, and CI keys its
artefact cache on it — see [Caching in CI](#caching-in-ci) below.

To force specific work:

```bash
rm build/dxvk.stamp                # rebuild DXVK only
rm build/sdl3.stamp                # rebuild SDL3 only
rm build/vkd3d-proton.stamp        # rebuild vkd3d-proton only
rm build/dxc.stamp                 # rebuild DXC (~19 min)
rm build/fidelityfx.stamp          # rebuild FidelityFX only (seconds)
rm build/dxc-host.stamp            # rebuild FidelityFX's stock DXC (~19 min)
rm build/ffmpeg.stamp              # re-stage FFmpeg (incremental make)
rm -rf build/ffmpeg-8.1            # re-extract and reconfigure FFmpeg
rm build/ffmpeg-8.1.tar.xz         # re-download the FFmpeg tarball
./build.sh --clean                 # rebuild everything from scratch
```

## Caching in CI

The GitHub Actions workflow caches each dependency's **staged output** — the
shipped `.so` files, anything a later step consumes (vkd3d-proton's installed
headers, which the FidelityFX build compiles against), plus that dependency's
`build/<dep>.stamp` — and restores them before `build.sh` runs. The restored stamp makes the script's own
"outputs present and stamp matches" check fire, so the step exits without
cloning or downloading anything. A fully warm run builds nothing and produces
all three archives in about five seconds; the cold run it replaces is about
half an hour.

The cache key is the stamp itself:

```
<dep>-ubuntu-24.04-gcc<version>-glibc<version>-<sha256 of the stamp, 32 chars>
```

taken from `--print-stamp` so the key and the on-disk stamp cannot drift
apart. Three consequences worth knowing:

* **A too-loose key cannot ship a stale binary.** The script re-derives its
  stamp on every run and compares; a mismatch rebuilds. The CI key is only a
  performance hint.
* **The toolchain is part of the key** because the staged libraries are linked
  against the runner's gcc and glibc, and the `ubuntu-24.04` image is patched
  in place — the image label alone would not notice a bump.
* **Caches are scoped by branch.** A run reads its own branch, the default
  branch, and (for a pull request) the base branch. A cache written by a PR
  lives on that PR's merge ref and cannot be read by `main` or by any other
  PR. So a dependency bump gets built twice — once on the PR, once on `main`
  after the merge — while everything the PR did not touch restores from
  `main`'s caches either way.

Restore and save are separate workflow steps rather than the combined cache
action, because the combined one only writes on a fully successful job: a
failure in a late dependency, or in the release step, would otherwise discard
everything the run had already built.

Nothing about this changes a local build — the stamps behave exactly as they
did before, and CI is simply seeding them.

## Output

After a successful run:

```
build/Libraries/                 staged SE1 tree (what the SE1 archive mirrors)
build/Libraries-SE2/             staged SE2 tree
build/Libraries-Steam/           staged Steam tree
dist/se1-dependencies.tar.gz     the SE1 release archive
dist/se2-dependencies.tar.gz     the SE2 release archive
dist/steam-dependencies.tar.gz   the Steam release archive
```

All of it is gitignored. See [release-archive.md](release-archive.md) for the
exact contents and the guarantees consumers rely on.

## Troubleshooting

**`ERROR: required tool not found in PATH: <tool>`** — install it; the table
above says which dependency needs it.

**`ERROR: DXC configured itself as PACKAGE_VERSION '...'`** — the DXC clone
under `build/dxc/` is not at the pinned tag. Usually a half-finished fetch;
`./Scripts/build_dxc.sh --clean` re-clones it.

**`ERROR: expected lib not built: libavcodec.so.62`** — FFmpeg's SOVERSION
moved in the build tree, which means the pinned version changed or upstream
bumped it (an ABI break for the consumers even though the shipped file names
stay bare). See [maintenance.md](maintenance.md) for what to update.

**OpenAL: `Required backend not found`** — a backend's development headers are
missing. Install `libpulse-dev`, `libasound2-dev` and `libpipewire-0.3-dev`.
This failure is deliberate: without it the build would quietly produce an
OpenAL with no audio backends.

**`SDL3 was configured without a video driver we ship for`** — the X11 or
Wayland development headers are missing, and SDL's CMake disabled that driver
without saying so. Install the two `libx*`/`libwayland*` groups from the table
above and rerun with `--clean`. Same rationale as the OpenAL check: SDL3 now
ships, so a library that loads fine and then fails at `SDL_CreateWindow` on
every user's machine has to be caught here.

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

**`ERROR: missing vendor blob:`** — a blob under `Vendor/` is absent. These
are committed; a fresh clone has them, so this usually means a partial
checkout.

**`ERROR: patch failed to apply:`** — a patch under `Patches/dxvk/` or
`Patches/vkd3d-proton/` no longer applies to the pinned upstream version,
usually after a version bump. Rebase the series; see
[maintenance.md](maintenance.md#bumping-dxvk).

**`ERROR: widl (Wine IDL compiler) not found in PATH.`** — install
`mingw-w64-tools` (Debian/Ubuntu) or `wine64-tools`; vkd3d-proton needs it
to generate its COM headers.
