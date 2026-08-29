# Architecture

## Why this repo exists

Space Engineers 1 is a Windows game. Running its client (Pulsar for Linux) or
its dedicated server (Magnetar) on Linux requires a set of native and managed
libraries that Keen does not ship for Linux: a self-contained FFmpeg, DXVK
Native for the Direct3D 11 layer, the managed Steamworks.NET binding, and the
proprietary EOS and Steamworks runtimes.

Before this repo existed, Pulsar and Magnetar each built their own copies of
these from near-identical shell scripts. That had three costs:

* **Duplication.** `build_steamworks_net.sh` existed twice, pinned to the same
  commit, and had to be kept in sync by hand.
* **Build time.** Every Pulsar CI run and every developer's first local build
  compiled FFmpeg and DXVK from source — tens of minutes each.
* **Drift risk.** Nothing guaranteed that the `libsteam_api.so` inside a Pulsar
  bundle was the same file as the one inside a Magnetar bundle.

This repo builds each library exactly once, publishes the result as a single
versioned release archive, and lets both consumers download it. That is the
same pattern already used by
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers)
for the PE-loader shims.

## Scope

### In scope — built or shipped here

| Artefact | Archives | Origin |
| --- | --- | --- |
| `libavcodec` / `libavformat` / `libavutil` / `libswresample` / `libswscale` | SE1 | FFmpeg 8.1, built from the upstream release tarball |
| `libdxvk_d3d11.so`, `libdxvk_dxgi.so` | both | DXVK Native 3.0.2 + the `Patches/dxvk/` series, built once from the upstream git tag |
| `libvkd3d-proton-d3d12.so`, `libvkd3d-proton-d3d12core.so` | SE2 | vkd3d-proton at a pinned commit + the `Patches/vkd3d-proton/` series |
| `libSDL3.so` | both | SDL3 3.4.12, built once from the upstream release tag; DXVK compiles against its headers and dlopens it at runtime |
| `libdxcompiler.so` | SE2 | DirectX Shader Compiler at tag `v1.9.2607` + the `Patches/dxc/` ABI compatibility patch, built from source rather than taken from Microsoft's binary release |
| `libopenal.so` | SE1 | OpenAL Soft 1.25.2, built from the upstream release tarball |
| `Steamworks.NET.dll` | Steam | Built from a pinned commit of rlabrecque/Steamworks.NET |
| `libEOSSDK-Linux-Shipping.so` | SE1 | Proprietary Epic blob, committed under `Vendor/` |
| `libsteam_api.so` | Steam | Proprietary Valve blob, committed under `Vendor/` |
| `libfmod.so`, `libfmodstudio.so` | SE2 | Proprietary Firelight blobs, committed under `Vendor/` |
| `LICENSES/*.txt` | all | Third-party licence texts and attribution, committed under `Licenses/` |

Three policies shape the archive split:

* **Patched libraries are built once and shipped as the same bytes
  everywhere they appear.** DXVK (see `Patches/dxvk/`) ships identically in
  the SE1 and SE2 archives — one build to test, no variant drift. The same
  holds for `libSDL3.so`, which DXVK dlopens: shipping the exact SDL3 the
  DXVK binaries were compiled against keeps the pair a matched set instead of
  depending on whatever the host distribution has.
* **Everything new with the SE2 port ships only in the SE2 archive.**
  vkd3d-proton, DXC and FMOD go to `se2-dependencies.tar.gz` alone,
  so SE1 consumers never download or ship libraries they cannot use.
* **ABI fixes live in the dependency source.** DXC's Windows-string
  conversions are applied from `Patches/dxc/` before the compiler is built,
  avoiding a separately version-coupled bridge library.
* **The Steam bits ship in their own archive.** `Steamworks.NET.dll` and
  `libsteam_api.so` belong together (the managed binding and its native
  runtime) and are game-agnostic, so `steam-dependencies.tar.gz` is
  consumed alongside either game archive and a Steamworks update republishes
  neither game payload.

### Out of scope — deliberately not here

**The native wrapper libraries** — SE1's PE-loader shims
(`libD3DCompiler.so`, `libHavok.so`, `libRecastDetour.so`,
`libVRageNative.so`) and SE2's `libVRage.*.Native.so` set — are built and
released by
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers).
Consumers fetch that release directly, in addition to this one.

They are kept separate on purpose. The wrappers change far more often than
FFmpeg or DXVK do, and re-bundling them here would mean every wrapper fix
required a full rebuild of this repo (~15 minutes of FFmpeg and DXVK
compilation) before Pulsar or Magnetar could pick it up. With two independent
releases, a wrapper fix reaches consumers as soon as its own CI is green.

## How the pieces fit together

```
  CometWorks/linux-dependencies            CometWorks/linux-native-wrappers
  (this repo)                              (PE-loader shims)
        |                                             |
        | release assets:                             | release asset:
        | se1-dependencies.tar.gz                     | linux-native-wrappers.tar.gz
        | se2-dependencies.tar.gz                     |
        | steam-dependencies.tar.gz                   |
        | (the SE2 asset is consumed by the SE2       |
        |  port, not shown below; the Steam asset     |
        |  is consumed by all of them)                |
        +---------------------+-----------------------+
                              |
                 fetched at build time by
                              |
              +---------------+---------------+
              |                               |
        Pulsar for Linux                  Magnetar
        (game client)                     (dedicated server)
              |                               |
        build/Libraries/                build/Libraries/
              |                               |
        copied next to the apphost by each repo's
        Legacy.csproj AfterBuild / AfterPublish target
```

Both consumers stage everything into a `build/Libraries/` folder whose contents
get copied next to the .NET apphost at publish time. That folder layout is the
reason the release archive is laid out the way it is: extracting the archive
into `build/Libraries/` is the entire staging step.

## Design decisions

### Everything is pinned

FFmpeg and OpenAL are pinned to a version (OpenAL additionally by tarball
checksum, since its URL is mutable), DXVK to a git tag, Steamworks.NET to a
commit SHA. No dependency resolves to "latest" at build time. A rebuild of an
unchanged tree produces functionally identical binaries, and a version bump is
always a visible commit.

### Verification lives next to the build

Each build script asserts its own outputs before staging them: FFmpeg checks
the SOVERSIONs against a table and runs an `ldd` allow-list to catch a
configure flag that leaked an unwanted host dependency; both FFmpeg and DXVK
verify that `DT_RUNPATH=$ORIGIN` actually landed in the ELF header. `build.sh`
then re-checks that every expected file exists before packaging.

The point is that a mistake surfaces here, with a clear message, rather than as
a `DllNotFoundException` inside Space Engineers three repos downstream.

### `DT_RUNPATH=$ORIGIN` on every native library

The shipped libraries reference each other (`libavformat` needs
`libavcodec`, which needs `libavutil`). Without an rpath, glibc resolves
those through the system search path, which does not include the
executable's own directory — so they would either fail to load or, worse,
silently bind to a different-ABI FFmpeg from the host's `ld.so.cache`.

Baking `$ORIGIN` into `DT_RUNPATH` makes each library find its siblings next
to itself, which means the consumer's launcher does not have to manipulate
`LD_LIBRARY_PATH` at all. Because the archives carry only bare, unversioned
file names, the built libraries' intra-bundle `NEEDED` entries are rewritten
to those bare names at staging time — otherwise they would ask the loader
for SONAME-named files that no longer ship.

### FFmpeg is built with almost everything disabled

The FFmpeg build disables every optional codec, hardware acceleration path,
network backend, and device backend, so the resulting `.so` files depend only
on glibc and zlib. That is what makes the bundle portable across distributions;
the `ldd` allow-list in `build_ffmpeg.sh` is what keeps it that way. See
[dependencies.md](dependencies.md) for the full flag rationale.

### The proprietary blobs are committed, not downloaded

EOS, Steamworks and FMOD have no public source and no publicly fetchable
binary — the downloads sit behind logged-in partner portals. Committing the
`.so` files under `Vendor/` is the only practical option; see
[Vendor/README.md](../Vendor/README.md) for their provenance and licensing.
