# The release archives

This document is the **contract** between this repo and its consumers. Pulsar
and Magnetar extract the archive straight into their own `build/Libraries/`
staging folder, so its layout is an API: changing it breaks them.

## Assets

Each release carries two assets:

```
linux-dependencies.tar.gz       Space Engineers 1 (Pulsar for Linux, Magnetar)
linux-dependencies-se2.tar.gz   Space Engineers 2 (the SE2 Linux port)
```

Both are gzip-compressed tars built by `build.sh` (roughly 24 MB and 7 MB).
The SE1 archive contains exactly the same library set as before the SE2
split; its patched DXVK binaries are **byte-identical to the SE2 archive's
copies** — built once, copied into both staging trees.

Download the latest with:

```bash
curl -fL -o linux-dependencies.tar.gz \
  https://github.com/CometWorks/linux-dependencies/releases/latest/download/linux-dependencies.tar.gz
```

```bash
curl -fL -o linux-dependencies-se2.tar.gz \
  https://github.com/CometWorks/linux-dependencies/releases/latest/download/linux-dependencies-se2.tar.gz
```

## Layout (SE1 archive)

Every library sits at the archive root; licence texts sit in a single
`LICENSES/` subdirectory. There is no top-level wrapper directory, so
`tar -xzf linux-dependencies.tar.gz -C <staging dir>` is the whole staging
step.

```
libavcodec.so                 -> libavcodec.so.62.28.100     (symlink)
libavcodec.so.62              -> libavcodec.so.62.28.100     (symlink)
libavcodec.so.62.28.100
libavformat.so                -> libavformat.so.62.12.100    (symlink)
libavformat.so.62             -> libavformat.so.62.12.100    (symlink)
libavformat.so.62.12.100
libavutil.so                  -> libavutil.so.60.26.100      (symlink)
libavutil.so.60               -> libavutil.so.60.26.100      (symlink)
libavutil.so.60.26.100
libswresample.so              -> libswresample.so.6.3.100    (symlink)
libswresample.so.6            -> libswresample.so.6.3.100    (symlink)
libswresample.so.6.3.100
libswscale.so                 -> libswscale.so.9.5.100       (symlink)
libswscale.so.9               -> libswscale.so.9.5.100       (symlink)
libswscale.so.9.5.100
libdxvk_d3d11.so                                      (patched, see Patches/dxvk/)
libdxvk_d3d11.so.0            -> libdxvk_d3d11.so     (symlink)
libdxvk_dxgi.so                                       (patched)
libdxvk_dxgi.so.0             -> libdxvk_dxgi.so      (symlink)
libEOSSDK-Linux-Shipping.so
libsteam_api.so
Steamworks.NET.dll
LICENSES/DXVK-LICENSE.txt
LICENSES/EOS-NOTICE.txt
LICENSES/FFmpeg-LGPL-2.1.txt
LICENSES/FFmpeg-README.txt
LICENSES/OpenAL-Soft-LGPL-2.0.txt
LICENSES/OpenAL-Soft-NOTICES.txt
LICENSES/OpenAL-Soft-README.txt
LICENSES/README.txt
LICENSES/Steam-NOTICE.txt
LICENSES/Steamworks.NET-LICENSE.txt
```

### Guarantees

* **Symlinks are stored as symlinks**, not dereferenced into duplicate files.
  Extract with GNU `tar` (or anything that preserves them) so the
  `libavcodec.so` → `.so.62` → `.so.62.28.100` chain survives. This is also why
  the archive is 23 MB rather than several times that.
* **Every native `.so` has `DT_RUNPATH=$ORIGIN`**, so the libraries find each
  other next to themselves and no `LD_LIBRARY_PATH` manipulation is needed.
* **The FFmpeg libraries depend only on glibc and libz.** Verified by an `ldd`
  allow-list at build time.
* **The archive is byte-reproducible** for a given set of inputs: `tar` is
  invoked with `--sort=name`, a fixed `--mtime`, and numeric owner 0:0.
* **`libD3DCompiler.so`, `libHavok.so`, `libRecastDetour.so` and
  `libVRageNative.so` are NOT in this archive.** They come from
  [CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers).

`build.sh` asserts this exact file list before packaging. If you change the
layout, update both that `EXPECTED_FILES` array and this document.

## Layout (SE2 archive)

Same conventions: everything at the archive root, licences under `LICENSES/`,
extraction into the consumer's staging directory is the whole staging step.

```
libdxvk_d3d11.so              identical to the SE1 archive's copy
libdxvk_d3d11.so.0            -> libdxvk_d3d11.so              (symlink)
libdxvk_dxgi.so               identical to the SE1 archive's copy
libdxvk_dxgi.so.0             -> libdxvk_dxgi.so               (symlink)
libvkd3d-proton-d3d12.so      patched, see Patches/vkd3d-proton/ (SE2 only)
libvkd3d-proton-d3d12core.so  patched (SE2 only)
libfmod.so.14                 FMOD Core API runtime (unmodified vendor blob)
libfmodstudio.so.14           FMOD Studio API runtime (unmodified vendor blob)
LICENSES/DXVK-LICENSE.txt
LICENSES/FMOD-EULA.txt
LICENSES/FMOD-NOTICE.txt
LICENSES/README.txt
LICENSES/VKD3D-LGPL-2.1.txt
LICENSES/vkd3d-proton-README.txt
```

The FMOD file names carry the upstream SONAMEs (`libfmod.so.14`), exactly as
the SE2 port consumes them — `libfmodstudio.so.14`'s `NEEDED` entry
references `libfmod` by that SONAME. The FMOD blobs are shipped
**unmodified** (no patchelf), matching how the EOS and Steamworks blobs are
handled; the built libraries carry `DT_RUNPATH=$ORIGIN` as everywhere else.
The SE2 native wrappers (`libVRage.*.Native.so`) are **not** in this
archive; like the SE1 wrappers, they come from
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers).

`build.sh` asserts the corresponding `EXPECTED_FILES_SE2` array before
packaging, same as the SE1 list.

## Which files each consumer needs

The SE1 archive is shared, so each SE1 consumer extracts all of it and uses
the subset it needs. Nothing breaks from staging an unused library, and
keeping one archive avoids a client/server split that would have to be
maintained forever.

| File | Pulsar (client) | Magnetar (server) |
| --- | :---: | :---: |
| FFmpeg libraries | yes | no |
| DXVK libraries | yes | no |
| OpenAL library | yes | no |
| `Steamworks.NET.dll` | yes | yes |
| `libsteam_api.so` | yes | yes |
| `libEOSSDK-Linux-Shipping.so` | yes | yes |
| `LICENSES/` | yes | the subset covering what it ships |

The SE2 archive is consumed only by the Space Engineers 2 Linux port, which
takes all of it. The two archives are kept separate — rather than a `se2/`
subdirectory inside the SE1 archive — so SE1 consumers never download or
ship SE2-only payload (vkd3d-proton, FMOD) and the SE1 archive's library
set stays exactly what it was before the split; the DXVK files it shares
with the SE2 archive are the same bytes in both.

## Versioning and tags

| Trigger | Release |
| --- | --- |
| Push to `main` | Public release tagged `v1.0.<run_number>`, marked **latest**, targeting the pushed commit |
| Push to a non-draft PR | **Draft** release tagged `pr-<number>`, refreshed on every push, no git tag until a maintainer publishes it |
| Push to a draft PR | Nothing — the workflow is skipped entirely |

`<run_number>` is the GitHub Actions run counter, so tags increase
monotonically. The version number tracks *this repo's* build, not any
dependency version — bumping FFmpeg does not change the `1.0` prefix. To find
out which dependency versions a release contains, look at the pins in
`Scripts/` at that release's commit.

Consumers resolve `releases/latest` by default and can pin an exact tag through
an environment variable; see [consuming.md](consuming.md).

## The CI workflow

[`.github/workflows/build.yml`](../.github/workflows/build.yml) installs the
toolchain, runs `./build.sh`, uploads the archive as a workflow artifact, and
publishes the release.

It pins **`ubuntu-24.04`** rather than `ubuntu-latest` on purpose. The
libraries are linked against the runner's glibc, and glibc is backwards but not
forwards compatible: binaries built on 24.04 (glibc 2.39) run on anything
newer, but a silent bump to a future `ubuntu-latest` would raise the minimum
glibc for every downstream user without any visible change in this repo.

Draft pull requests are skipped so that work in progress does not spend CI
minutes on a 15-minute FFmpeg and DXVK build.
