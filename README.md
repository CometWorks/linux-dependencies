# Linux Dependencies

Build and release of the Linux library dependencies of the Space Engineers
client and server (version 1), plus a companion archive for the Space
Engineers 2 client.

Used by the Linux builds of [Pulsar](https://github.com/CometWorks/Pulsar) and
[Magnetar](https://github.com/CometWorks/magnetar), which download the
published release archive instead of building these libraries themselves.

## What it ships

Three release assets. The game archives carry the game-specific libraries
(the patched DXVK build is byte-identical in both); the Steam bits ship in
their own archive, consumed alongside either game archive.

### `se1-dependencies.tar.gz` — Space Engineers 1

| Artefact | Version | Licence |
| --- | --- | --- |
| FFmpeg (`libavcodec`, `libavformat`, `libavutil`, `libswresample`, `libswscale`) | 8.1 | LGPL-2.1-or-later |
| DXVK Native (`libdxvk_d3d11.so`, `libdxvk_dxgi.so`) + [Patches/dxvk/](Patches/dxvk/) | 3.0.2 | zlib |
| SDL3 (`libSDL3.so`) — dlopened by DXVK's window-system integration | 3.4.12 | zlib |
| OpenAL Soft (`libopenal.so`) | 1.25.2 | LGPL-2.0-or-later |
| `libEOSSDK-Linux-Shipping.so` | vendor blob | proprietary (Epic) |

### `se2-dependencies.tar.gz` — Space Engineers 2

| Artefact | Version | Licence |
| --- | --- | --- |
| DXVK Native — same patched build as above | 3.0.2 | zlib |
| SDL3 — same build as above | 3.4.12 | zlib |
| vkd3d-proton (`libvkd3d-proton-d3d12.so`, `libvkd3d-proton-d3d12core.so`) + [Patches/vkd3d-proton/](Patches/vkd3d-proton/) | pinned commit | LGPL-2.1 |
| FMOD Engine (`libfmod.so`, `libfmodstudio.so`) | 2.03.11, matching the game | proprietary (Firelight) |

### `steam-dependencies.tar.gz` — Steam integration

| Artefact | Version | Licence |
| --- | --- | --- |
| `Steamworks.NET.dll` | pinned commit | MIT |
| `libsteam_api.so` | vendor blob | proprietary (Valve) |

Everything, plus the third-party licence texts, is published as release
assets on every release.

The native wrapper libraries — SE1's PE-loader shims (`libD3DCompiler.so`,
`libHavok.so`, `libRecastDetour.so`, `libVRageNative.so`) and SE2's
`libVRage.*.Native.so` set — are **not** part of this repo; they come from
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers).

## Using it

```bash
curl -fL -o se1-dependencies.tar.gz \
  https://github.com/CometWorks/linux-dependencies/releases/latest/download/se1-dependencies.tar.gz
curl -fL -o steam-dependencies.tar.gz \
  https://github.com/CometWorks/linux-dependencies/releases/latest/download/steam-dependencies.tar.gz
tar -xzf se1-dependencies.tar.gz -C <your staging dir>
tar -xzf steam-dependencies.tar.gz -C <your staging dir>
```

See [docs/consuming.md](docs/consuming.md) for how Pulsar and Magnetar wire
this into their builds.

## Building it

```bash
./build.sh
```

Builds everything from source, stages `build/Libraries/` (SE1),
`build/Libraries-SE2/` (SE2) and `build/Libraries-Steam/` (Steam), and
packages the three archives under `dist/`. See
[docs/building.md](docs/building.md) for prerequisites and options.

## Documentation

Full documentation index: **[docs/README.md](docs/README.md)**

* [Architecture](docs/architecture.md) — why this repo exists and what is in scope
* [Dependencies](docs/dependencies.md) — each library, its pin, and why it is built that way
* [Building](docs/building.md) — prerequisites, `build.sh` usage, caching, troubleshooting
* [Release archive](docs/release-archive.md) — the archive contract and the CI workflow
* [Consuming](docs/consuming.md) — how Pulsar and Magnetar fetch it
* [Maintenance](docs/maintenance.md) — bumping versions and updating vendor blobs

## Licence

The build scripts in this repository are MIT-licensed (see [LICENSE](LICENSE)).
The libraries they produce are covered by their own licences, collected in
[Licenses/](Licenses/) and shipped inside the release archive as `LICENSES/`.
