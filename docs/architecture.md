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

| Artefact | Origin |
| --- | --- |
| `libavcodec` / `libavformat` / `libavutil` / `libswresample` / `libswscale` | FFmpeg 8.1, built from the upstream release tarball |
| `libdxvk_d3d11.so`, `libdxvk_dxgi.so` | DXVK Native 2.7.1, built from the upstream git tag |
| `Steamworks.NET.dll` | Built from a pinned commit of rlabrecque/Steamworks.NET |
| `libEOSSDK-Linux-Shipping.so` | Proprietary Epic blob, committed under `Vendor/` |
| `libsteam_api.so` | Proprietary Valve blob, committed under `Vendor/` |
| `LICENSES/*.txt` | Third-party licence texts and attribution, committed under `Licenses/` |

### Out of scope — deliberately not here

**The native wrapper libraries** (`libD3DCompiler.so`, `libHavok.so`,
`libRecastDetour.so`, `libVRageNative.so`) are built and released by
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
        | release asset:                              | release asset:
        | linux-dependencies.tar.gz                   | linux-native-wrappers.tar.gz
        |                                             |
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

FFmpeg is pinned to a version, DXVK to a git tag, Steamworks.NET to a commit
SHA. No dependency resolves to "latest" at build time. A rebuild of an
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
`libavcodec.so.62`, which needs `libavutil.so.60`). Without an rpath, glibc
resolves those through the system search path, which does not include the
executable's own directory — so they would either fail to load or, worse,
silently bind to a different-ABI FFmpeg from the host's `ld.so.cache`.

Baking `$ORIGIN` into `DT_RUNPATH` makes each library find its siblings next to
itself, which means the consumer's launcher does not have to manipulate
`LD_LIBRARY_PATH` at all.

### FFmpeg is built with almost everything disabled

The FFmpeg build disables every optional codec, hardware acceleration path,
network backend, and device backend, so the resulting `.so` files depend only
on glibc and zlib. That is what makes the bundle portable across distributions;
the `ldd` allow-list in `build_ffmpeg.sh` is what keeps it that way. See
[dependencies.md](dependencies.md) for the full flag rationale.

### The proprietary blobs are committed, not downloaded

EOS and Steamworks have no public source and no publicly fetchable binary — the
downloads sit behind logged-in partner portals. Committing the two `.so` files
under `Vendor/` is the only practical option; see
[Vendor/README.md](../Vendor/README.md) for their provenance and licensing.
