# The release archives

This document is the **contract** between this repo and its consumers. Pulsar
and Magnetar extract the archive straight into their own `build/Libraries/`
staging folder, so its layout is an API: changing it breaks them.

## Assets

Each release carries three assets:

```
se1-dependencies.tar.gz     Space Engineers 1 (Pulsar for Linux, Magnetar)
se2-dependencies.tar.gz     Space Engineers 2 (the SE2 Linux port)
steam-dependencies.tar.gz   Steamworks.NET.dll + libsteam_api.so, consumed
                            alongside either game archive
```

All are gzip-compressed tars built by `build.sh` (roughly 24 MB, 7 MB and
250 kB). The patched DXVK binaries are **byte-identical across the two game
archives** — built once, copied into both staging trees.

Download the latest with (same pattern for the other two assets):

```bash
curl -fL -o se1-dependencies.tar.gz \
  https://github.com/CometWorks/linux-dependencies/releases/latest/download/se1-dependencies.tar.gz
```

## Layout (SE1 archive)

Every library sits at the archive root as a **single real file under its
bare, unversioned name** — no symlinks, no version-suffixed filenames.
Licence texts sit in a single `LICENSES/` subdirectory. There is no
top-level wrapper directory, so
`tar -xzf se1-dependencies.tar.gz -C <staging dir>` is the whole staging
step.

```
libavcodec.so
libavformat.so
libavutil.so
libswresample.so
libswscale.so
libdxvk_d3d11.so              (patched, see Patches/dxvk/)
libdxvk_dxgi.so               (patched)
libEOSSDK-Linux-Shipping.so
LICENSES/DXVK-LICENSE.txt
LICENSES/EOS-NOTICE.txt
LICENSES/FFmpeg-LGPL-2.1.txt
LICENSES/FFmpeg-README.txt
LICENSES/OpenAL-Soft-LGPL-2.0.txt
LICENSES/OpenAL-Soft-NOTICES.txt
LICENSES/OpenAL-Soft-README.txt
LICENSES/README.txt
```

### Guarantees

* **No symlinks and no version-suffixed filenames.** Each library is one
  real file under its bare name. The SONAMEs *inside* the built binaries are
  left as upstream produced them (useful for identifying the version with
  `readelf`), but no file is named after them.
* **Intra-bundle `NEEDED` entries reference the bare file names.** The
  built libraries' cross-references (libavformat → libavcodec → libavutil,
  libdxvk_d3d11 → libdxvk_dxgi) are rewritten with
  `patchelf --replace-needed` at staging time, so together with
  `DT_RUNPATH=$ORIGIN` they resolve against the files actually present.
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
libdxvk_dxgi.so               identical to the SE1 archive's copy
libvkd3d-proton-d3d12.so      patched, see Patches/vkd3d-proton/ (SE2 only)
libvkd3d-proton-d3d12core.so  patched (SE2 only)
libfmod.so                    FMOD Core API runtime (unmodified vendor blob)
libfmodstudio.so              FMOD Studio API runtime (unmodified vendor blob)
LICENSES/DXVK-LICENSE.txt
LICENSES/FMOD-EULA.txt
LICENSES/FMOD-NOTICE.txt
LICENSES/README.txt
LICENSES/VKD3D-LGPL-2.1.txt
LICENSES/vkd3d-proton-README.txt
```

The FMOD blobs are shipped **unmodified** (no patchelf), matching how the
EOS and Steamworks blobs are handled — only their file names are the bare
ones. That means `libfmodstudio.so`'s internal `NEEDED` entry still
references the upstream SONAME `libfmod.so.14`, which no shipped file
carries: **the consumer must load `libfmod.so` before `libfmodstudio.so`**
(the already-loaded library then satisfies the reference by SONAME). The
built libraries carry `DT_RUNPATH=$ORIGIN` and bare-name `NEEDED` entries as
in the SE1 archive. The SE2 native wrappers (`libVRage.*.Native.so`) are
**not** in this archive; like the SE1 wrappers, they come from
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers).

`build.sh` asserts the corresponding `EXPECTED_FILES_SE2` array before
packaging, same as the SE1 list.

## Layout (Steam archive)

Same conventions. Consumed alongside either game archive by any bundle that
integrates with Steam; the two files belong together (the managed binding
and the native runtime it P/Invokes).

```
Steamworks.NET.dll
libsteam_api.so
LICENSES/README.txt
LICENSES/Steam-NOTICE.txt
LICENSES/Steamworks.NET-LICENSE.txt
```

`build.sh` asserts the corresponding `EXPECTED_FILES_STEAM` array before
packaging.

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
| `libEOSSDK-Linux-Shipping.so` | yes | yes |
| `LICENSES/` | yes | the subset covering what it ships |
| Steam archive (`Steamworks.NET.dll` + `libsteam_api.so`) | yes | yes |

The SE2 archive is consumed only by the Space Engineers 2 Linux port, which
takes all of it (plus the Steam archive). The archives are kept separate —
rather than subdirectories of one archive — so consumers never download or
ship payload they cannot use, and a Steamworks update republishes neither
game payload; the DXVK files shared between the game archives are the same
bytes in both.

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
