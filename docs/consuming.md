# Consuming the release

Both [Pulsar for Linux](https://github.com/CometWorks/Pulsar) (`linux` branch)
and [Magnetar](https://github.com/CometWorks/magnetar) fetch the release
archive at build time instead of building these dependencies themselves.

Each consumer has a `Scripts/fetch_linux_dependencies.sh` that resolves a
release, downloads `linux-dependencies.tar.gz`, and extracts it into that
repo's `build/Libraries/` staging folder. The two copies are deliberately
near-identical, and they mirror the existing `fetch_native_wrappers.sh` in both
repos so there is one fetch pattern to understand rather than two.

## What the fetch script does

1. **Resolve the tag.** With `LINUX_DEPENDENCIES_TAG` set, that exact tag is
   used. Otherwise the GitHub API is asked for the latest release.
   `GH_TOKEN` / `GITHUB_TOKEN`, if present, is used only to lift the anonymous
   API rate limit.
2. **Check the cache.** `build/linux-dependencies.stamp` records the tag last
   staged. If it matches the resolved tag and every expected file is present in
   `build/Libraries/`, the download is skipped.
3. **Download and extract** into `build/Libraries/`, preserving symlinks.
4. **Verify** that the files that consumer needs actually arrived.

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
Scripts/fetch_linux_dependencies.sh   -> FFmpeg, DXVK, Steamworks.NET,
                                         EOS + Steam blobs, LICENSES/
Scripts/fetch_native_wrappers.sh      -> libD3DCompiler.so, libHavok.so,
                                         libRecastDetour.so, libVRageNative.so
```

Both land in `build/Libraries/`, and the script's final assertion — the full
expected-file list, unchanged from before this split — confirms the combined
result. `Legacy/Legacy.csproj` copies that folder next to the apphost in its
`AfterBuild` and `AfterPublish` targets, and `Shared/Shared.csproj` references
`build/Libraries/Steamworks.NET.dll`; neither needed any change, because
`build/Libraries/` still ends up with exactly the same contents.

## Magnetar

Magnetar is headless, so it uses the managed assembly and the two proprietary
blobs but not FFmpeg or DXVK. Its `build.sh` extracts the archive and stages
the subset it needs, then fetches the native wrappers as before.

Magnetar keeps its per-library environment overrides (`LIBSTEAM_API_SO`,
`LIBEOSSDK_SO`, `LIBHAVOK_SO`, `LIBRECASTDETOUR_SO`, `LIBVRAGENATIVE_SO`) and
its `$DS64` probe. Those take precedence over the fetched archive, so a
developer can still point the build at a locally supplied `libsteam_api.so`
without touching the release.

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
