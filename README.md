# Linux Dependencies

Build and release of the Linux library dependencies of the Space Engineers
client and server (version 1).

Used by the Linux builds of [Pulsar](https://github.com/CometWorks/Pulsar) and
[Magnetar](https://github.com/CometWorks/magnetar), which download the
published release archive instead of building these libraries themselves.

## What it ships

| Artefact | Version | Licence |
| --- | --- | --- |
| FFmpeg (`libavcodec`, `libavformat`, `libavutil`, `libswresample`, `libswscale`) | 8.1 | LGPL-2.1-or-later |
| DXVK Native (`libdxvk_d3d11.so`, `libdxvk_dxgi.so`) | 2.7.1 | zlib |
| OpenAL Soft (`libopenal.so`) | 1.25.2 | LGPL-2.0-or-later |
| `Steamworks.NET.dll` | pinned commit | MIT |
| `libEOSSDK-Linux-Shipping.so` | vendor blob | proprietary (Epic) |
| `libsteam_api.so` | vendor blob | proprietary (Valve) |

All of it, plus the third-party licence texts, is published as a single
`linux-dependencies.tar.gz` asset on every release.

The PE-loader wrapper libraries (`libD3DCompiler.so`, `libHavok.so`,
`libRecastDetour.so`, `libVRageNative.so`) are **not** part of this repo — they
come from
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers).

## Using it

```bash
curl -fL -o linux-dependencies.tar.gz \
  https://github.com/CometWorks/linux-dependencies/releases/latest/download/linux-dependencies.tar.gz
tar -xzf linux-dependencies.tar.gz -C <your staging dir>
```

See [docs/consuming.md](docs/consuming.md) for how Pulsar and Magnetar wire
this into their builds.

## Building it

```bash
./build.sh
```

Builds everything from source, stages `build/Libraries/`, and packages
`dist/linux-dependencies.tar.gz`. See [docs/building.md](docs/building.md) for
prerequisites and options.

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
