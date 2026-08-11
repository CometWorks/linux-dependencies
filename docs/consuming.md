# Consuming the release

Both [Pulsar for Linux](https://github.com/CometWorks/Pulsar) (`linux` branch)
and [Magnetar](https://github.com/CometWorks/magnetar) fetch the SE1 release
archive (`linux-dependencies.tar.gz`) at build time instead of building these
dependencies themselves. The SE2 archive (`linux-dependencies-se2.tar.gz`) is
for the Space Engineers 2 Linux port — see
[the SE2 archive](#the-se2-archive) below.

Each consumer has a `Scripts/fetch_linux_dependencies.sh` that resolves a
release and downloads `linux-dependencies.tar.gz`. The two copies are
deliberately near-identical, and they mirror the existing
`fetch_native_wrappers.sh` in both repos so there is one fetch pattern to
understand rather than two.

They differ in where they extract, because the consumers stage differently:
Pulsar uses the whole archive and extracts straight into `build/Libraries/`,
while Magnetar needs only part of it and extracts into a `build/linux-deps/`
cache that its `build.sh` then copies the wanted files out of.

## What the fetch script does

1. **Resolve the tag.** With `LINUX_DEPENDENCIES_TAG` set, that exact tag is
   used. Otherwise the GitHub API is asked for the latest release.
   `GH_TOKEN` / `GITHUB_TOKEN`, if present, is used only to lift the anonymous
   API rate limit.
2. **Check the cache.** `build/linux-dependencies.stamp` records the tag last
   staged. If it matches the resolved tag and every expected file is already
   present, the download is skipped.
3. **Clear what the previous release staged.** `tar` only overlays, so without
   this a release that renames a file — an FFmpeg SOVERSION bump, say — would
   leave the old one behind and the consumer would ship both. Pulsar extracts
   into a directory it shares with the native-wrapper fetch, so it records a
   `build/linux-dependencies.manifest` of the paths each release owns and
   removes only those. Magnetar extracts into a directory of its own and can
   simply wipe it.
4. **Download and extract**, preserving symlinks — `tar -xz`, never a
   dereferencing copy, or the `libavcodec.so` → `.so.62` → `.so.62.28.100`
   chain that FFmpeg's SONAME resolution needs would be flattened.
5. **Verify** that the files that consumer needs actually arrived.

If the GitHub API is unreachable but a cached copy is already staged, the
cached copy is reused rather than failing the build — the same
network-resilience behaviour `fetch_native_wrappers.sh` has.

### Environment overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `LINUX_DEPENDENCIES_REPO` | `CometWorks/linux-dependencies` | Point at a fork |
| `LINUX_DEPENDENCIES_TAG` | *(empty — latest release)* | Pin an exact tag. Recommended for reproducible CI |
| `GH_TOKEN` / `GITHUB_TOKEN` | *(unset)* | Raise the GitHub API rate limit |

Pinning a tag is a one-line change:

```bash
LINUX_DEPENDENCIES_TAG=v1.0.7 ./build.sh
```

## Pulsar for Linux

`Scripts/build_dependencies.sh` orchestrates two fetches and nothing else:

```
Scripts/fetch_linux_dependencies.sh   -> FFmpeg, DXVK, OpenAL, Steamworks.NET,
                                         EOS + Steam blobs, LICENSES/
Scripts/fetch_native_wrappers.sh      -> libD3DCompiler.so, libHavok.so,
                                         libRecastDetour.so, libVRageNative.so
```

Both land directly in `build/Libraries/`, and the script's final assertion —
the full expected-file list, unchanged from before this split — confirms the
combined result. `Legacy/Legacy.csproj` copies that folder next to the apphost
in its `AfterBuild` and `AfterPublish` targets, and `Shared/Shared.csproj`
references `build/Libraries/Steamworks.NET.dll`; neither needed any change,
because `build/Libraries/` still ends up with exactly the same contents.

Pulsar's own `Scripts/build_ffmpeg.sh`, `build_dxvk.sh` and
`build_steamworks_net.sh` are gone, along with its `Vendor/` directory and
`Scripts/Licenses/`. A clean build no longer spends roughly fifteen minutes
compiling FFmpeg and DXVK.

## Magnetar

Magnetar is headless, so it takes `Steamworks.NET.dll` and the two proprietary
runtimes but not FFmpeg, DXVK or OpenAL — those stay unused in
`build/linux-deps/` and never reach the bundle. Its `build.sh` fetches both
releases and then stages only the files it wants into `build/Libraries/`.

That applies to the licence texts too. Copying `LICENSES/` wholesale would put
FFmpeg, DXVK and OpenAL attribution into a bundle containing none of those
libraries, and the archive's own `LICENSES/README.txt` index would list files
that are not there. Magnetar therefore stages just the three notices covering
what it ships — `Steamworks.NET-LICENSE.txt`, `Steam-NOTICE.txt` and
`EOS-NOTICE.txt` — removes any notice a previous build left behind, and writes
its own `README.txt` describing that subset.

This replaced a genuinely manual step. The proprietary Steamworks and EOS
runtimes were never committed to Magnetar; a contributor had to obtain them
from the vendor portals and drop them in `Vendor/`, and CI pulled them from a
`Vendor.7z` behind a `VENDOR_ARCHIVE_URL` repository secret. A clean clone now
builds with no manual file shuffling, and the release workflow needs no
secrets at all.

Every library is probed in the same order, most specific first:

1. its own environment override (`STEAMWORKS_NET_DLL`, `LIBSTEAM_API_SO`,
   `LIBEOSSDK_SO`, `LIBHAVOK_SO`, `LIBRECASTDETOUR_SO`, `LIBVRAGENATIVE_SO`)
2. `<repo>/Vendor/<name>` — not committed any more, but the probe stays so a
   developer can override without setting env vars
3. the fetched release cache
4. for `libsteam_api.so` only, the `$DS64` dedicated-server folder

So a locally supplied `.so` still wins over the release, and `build.sh` prints
exactly which path each file came from.

## The SE2 archive

The Space Engineers 2 Linux port consumes `linux-dependencies-se2.tar.gz`,
which carries the patched DXVK build (byte-identical to the SE1 archive's
copy), the patched vkd3d-proton build, and the FMOD Engine runtime — see
[release-archive.md](release-archive.md#layout-se2-archive) for the exact
contents. It follows the same fetch pattern (same release, second asset name)
and the same rules: extract with symlink-preserving `tar`, keep `LICENSES/`
next to the binaries. The SE2 native wrappers (`libVRage.*.Native.so`) come
from the linux-native-wrappers release, fetched separately — the same split
as for SE1.

Two SE2-specific notes:

* The FMOD blobs ship **unmodified** (no `DT_RUNPATH` patching), and
  `libfmodstudio.so.14` references `libfmod` by its SONAME
  (`libfmod.so.14`). Load (or preload) `libfmod.so.14` before
  `libfmodstudio.so.14`, or make sure the staging directory is on the
  loader's search path for that resolution.
* The asset exists only from the release that introduced it onward; a fetch
  script should fail with a clear message when the asset is missing from an
  older pinned tag.

## Adding a new consumer

1. Copy `fetch_linux_dependencies.sh` from either repo.
2. Adjust its expected-file list to the subset you need.
3. Call it before your build, and make sure the staging folder ends up next to
   your apphost.
4. Ship `LICENSES/` alongside the binaries — the attribution requirements
   travel with them.

If your consumer also needs the PE-loader wrappers, fetch
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers)
separately; see [architecture.md](architecture.md#scope) for why the two
releases are kept apart.
