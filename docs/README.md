# Documentation

Build and release pipeline for the Linux binary dependencies of Space
Engineers (version 1), consumed by [Pulsar for
Linux](https://github.com/CometWorks/Pulsar) and
[Magnetar](https://github.com/CometWorks/magnetar).

## Contents

| Document | What it covers |
| --- | --- |
| [architecture.md](architecture.md) | Why this repo exists, what is in and out of scope, how it relates to the consuming repos |
| [dependencies.md](dependencies.md) | Each shipped library: what it is, where it comes from, how it is pinned, why it is built the way it is |
| [building.md](building.md) | Building locally: prerequisites, `build.sh` usage, caching, troubleshooting |
| [release-archive.md](release-archive.md) | The release archive contract: layout, exact file list, tagging, the CI workflow |
| [consuming.md](consuming.md) | How Pulsar and Magnetar fetch and stage the archive |
| [maintenance.md](maintenance.md) | Bumping a dependency version, updating a vendor blob, and what has to change in lockstep |

## Quick start

```bash
./build.sh
```

That builds everything from source, stages it in `build/Libraries/`, and
packages `dist/linux-dependencies.tar.gz`. See [building.md](building.md) for
prerequisites and options.
