# Maintenance

Common maintainer tasks and the things that have to change in lockstep with
each of them.

## The release loop

Every push to `main` publishes a new public release, so the normal flow is:

1. Branch, make the change, run `./build.sh` locally.
2. Open a pull request. CI builds it and attaches a **draft** release
   (`pr-<number>`) you can download and test against a real consumer.
3. Merge. CI publishes `v1.0.<run_number>` as the new latest release.
4. Consumers pick it up on their next build — no change needed on their side
   unless they pin a tag.

## Bumping FFmpeg

1. Set `FFMPEG_VERSION` in `Scripts/build_ffmpeg.sh`.
2. Build. If the SOVERSIONs moved, the script fails with `expected lib not
   built: …` — that failure is the point.
3. On a SOVERSION change, update `EXPECTED_SOVER` in
   `Scripts/build_ffmpeg.sh` and update the version table in
   `Licenses/FFmpeg-README.txt`. The archive file names are the bare,
   unversioned ones, so `EXPECTED_FILES` and the consumers' file lists do
   not change — but a SOVERSION shift is an upstream ABI bump, so confirm
   the FFmpeg.AutoGen version Pulsar uses matches the new FFmpeg major
   version before shipping it.
4. Check the `ldd` allow-list still passes. A new upstream release sometimes
   enables something by default that the disable list did not anticipate.

## Bumping DXVK

1. Set `DXVK_VERSION` in `Scripts/build_dxvk.sh` to the new tag (without the
   leading `v`; the script adds it).
2. Build. The stamp file invalidates automatically.
3. **Rebase the patch series.** If any patch under `Patches/dxvk/` no longer
   applies, the build fails naming the patch. Regenerate the series against
   the new tag (apply on a scratch clone, resolve, re-export with `git diff`
   / `git format-patch`) and update the provenance table in
   `Patches/dxvk/README.md`.
4. If upstream ever renames `package-native.sh` or changes its arguments, the
   build fails at that call — adjust the invocation rather than
   re-implementing the meson build.
5. DXVK's Vulkan requirements move over time. A newer DXVK may need a newer
   `libvulkan-dev` on the runner and a newer Vulkan driver on users' machines;
   check upstream's release notes before bumping across a major version.

## Bumping vkd3d-proton

Same shape as DXVK: set `VKD3D_PROTON_COMMIT` in
`Scripts/build_vkd3d_proton.sh` (a full 40-character SHA), build, rebase
`Patches/vkd3d-proton/` if a patch stops applying, and update its README's
provenance notes. The current pin is the upstream state the SE2 port's patch
series was developed against, so treat a bump as requiring an SE2 smoke test.

## Bumping DXC

`Scripts/build_dxc.sh` pins both `DXC_TAG` and `DXC_COMMIT`; set the two
together, since the script fails if the tag does not resolve to the SHA.

1. Stay on the **stable** line. Every `v1.10.x` release is flagged as a
   prerelease upstream (Shader Model 6.10 preview) and `v1.10.2605.24` was
   seen aborting inside LLVM while compiling SE2's Render12 shaders.
2. Read upstream's release notes for breaking HLSL changes and check SE2's
   shader sources against them — `v1.9.2607` disallowing `volatile` is the
   kind of change that matters.
3. Rebase `Patches/dxc/` and re-check its compiler, result and include-handler
   boundary edits against the new implementations.
4. Rebuild and smoke-test SE2 shader compilation. `DXC_KEEP_BUILD_TREE=1`
   makes the ~19 minute build reusable while iterating.
5. Refresh `Licenses/se2/DXC-README.txt` (it names the tag and commit),
   `Licenses/se2/DXC-LICENSE.txt` if upstream's `LICENSE.TXT` changed, and
   `Licenses/se2/DXC-BUNDLED-LICENSES.txt` if the SPIRV-Tools, SPIRV-Headers
   or DirectX-Headers submodule licences changed.
6. The shipped file names stay bare, so no expected-file list changes.

Editing the DXC patch needs no version bump: the patch-series hash is part of
`build/dxc.stamp`, so the next build rebuilds DXC automatically.

## Bumping the FidelityFX SDK

`Scripts/build_fidelityfx.sh` pins two tags of the same repository:
`FIDELITYFX_TAG`/`FIDELITYFX_COMMIT` for the SDK and
`FFX_SC_TAG`/`FFX_SC_COMMIT` for the shader permutation compiler. Set each tag
and SHA together; the script fails if a tag does not resolve to its pinned
SHA.

1. Check what the game asks for before bumping the SDK. `VRage.Render12`'s
   `FSR4_1Context` hard-codes the `ffxApiHeader` struct type IDs and the
   layout of `ffxCreateContextDescUpscale` / `ffxDispatchDescUpscale`; a
   release that changes either breaks the ABI silently, in a way only a
   running game shows.
2. Re-check the licence. This build compiles only files named in the
   exception list of the SDK's own `docs/license.md`; anything outside that
   list carries AMD's default binary-redistribution terms instead of MIT. A
   new release can move files between the two.
3. Rebase `Patches/fidelityfx/sdk/` and rebuild. The DX12 backend patch is
   the one most likely to conflict.
4. Leave `FFX_SC_TAG` at `v1.1.4` unless upstream publishes the shader
   compiler's source again — the 2.x releases ship it as a Windows binary
   only. If a new SDK changes the generated permutation header format (as
   2.x did by adding `entryName`), that is a change to
   `Patches/fidelityfx/ffx-sc/`.
5. Re-transcribe `upscalers/fsr3/dx12/BuildFSR3UpscalerShaders.bat` into the
   shader generation block of `Scripts/build_fidelityfx.sh` if its define sets
   or shader models changed.
6. Refresh `Licenses/se2/FidelityFX-README.txt` (it names the tag and commit)
   and `Licenses/se2/FidelityFX-LICENSE.txt` if the SDK's licence text
   changed.
7. Smoke-test in-game: the log line `FSR upscaler provider selected: 3.1.5`
   plus a rendered frame. A provider that fails to create takes the render
   thread with it.

The host DXC pin is *not* configured here — it is read out of
`Scripts/build_dxc.sh`, so bumping DXC bumps both. That is deliberate: the
shader compiler has to match the compiler the game's own shaders are built
with.

## Changing a patch series

Add, edit or remove `Patches/<dep>/NNNN-*.patch` files; each series' hash is
part of its dependency's cache stamp, so the next build rebuilds that
dependency automatically. The patched DXVK ships **in both archives** (built
once, copied), so a DXVK patch change affects SE1 and SE2 consumers alike —
test accordingly; vkd3d-proton ships in the SE2 archive only. For every
patch, record in the series' README.md what it fixes and where it came from.
Patches are applied with `git apply` in byte-wise filename order. DXC patches
ship in the SE2 archive only. `Patches/fidelityfx/` is the one series with
subdirectories — `sdk/` and `ffx-sc/`, applied to two different checkouts —
but its hash covers both, so either one invalidates the cache.

## Bumping SDL3

SDL3 both supplies headers for the DXVK build and ships as `libSDL3.so` in
**both game archives**, so a bump changes what users run, not just what DXVK
compiles against. Test accordingly.

1. Set `SDL3_VERSION` in `Scripts/build_sdl3.sh` (the upstream tag is
   `release-$SDL3_VERSION`).
2. Build. If upstream bumps the SONAME past `libSDL3.so.0`, the script fails
   with an explicit message; update `EXPECTED_SONAME` there — and check the
   consumers, because DXVK dlopens the SONAME and the shipped file is named
   `libSDL3.so`, so the two only meet through the consumer's preload.
3. The shipped file name stays bare, so no expected-file list changes.
4. Refresh `Licenses/SDL3-README.txt` — it names the version and the tag —
   and re-copy `Licenses/SDL3-LICENSE.txt` from upstream's `LICENSE.txt` if
   the copyright line moved.

If you change the cmake options in `build_sdl3.sh` rather than the version,
bump `CONFIG_REV` in the same file. It is part of the cache stamp, and without
a bump an existing `build/` tree re-stages the old, differently configured
library instead of rebuilding.

Since DXVK dlopens SDL3 rather than linking it, the version built here does
not constrain the host — but it is now the copy users actually get, so prefer
a released tag over a development one.

## Bumping OpenAL Soft

1. Set `OPENAL_VERSION` **and** `OPENAL_SHA256` in `Scripts/build_openal.sh`.
   The tarball URL is mutable, so the checksum is the pin — a version bump
   without a matching checksum fails the download verification, by design.
2. Build. If upstream bumps the SONAME past `libopenal.so.1`, the script
   fails with an explicit message; update `EXPECTED_SONAME` there. The
   shipped file name stays the bare `libopenal.so`, so no file list changes
   — but a SONAME bump is an upstream ABI break, so review the consumers
   before shipping it.
3. Check the `ldd` allow-list still passes. A new backend that links rather
   than dlopens would show up there.
4. Update the version in `Licenses/OpenAL-Soft-README.txt`, and re-copy
   `COPYING`, `BSD-3Clause` and `LICENSE-pffft` from the new tarball if
   upstream changed them.

## Bumping Steamworks.NET

1. Set `STEAMWORKS_NET_COMMIT` in `Scripts/build_steamworks_net.sh`.
2. Build. If the new commit is not reachable from a branch or tag, the script
   automatically fetches `refs/pull/*/head` and retries.
3. If the new commit predates `Standalone3.0/`, the script fails with a clear
   message; switch it to the `Standalone/` project or pick a different commit.
4. A Steamworks SDK version bump in Steamworks.NET usually needs a matching
   `libsteam_api.so` — see the next section. Mismatched versions produce
   confusing runtime failures rather than a clean error.

## Updating a vendor blob

`libEOSSDK-Linux-Shipping.so` and `libsteam_api.so` are proprietary and
manually maintained.

1. Download the SDK from the vendor portal:
   * EOS: <https://dev.epicgames.com/portal/> → your product → SDK Downloads →
     "EOS SDK for C" → Linux build.
   * Steamworks: <https://partner.steamgames.com/downloads/list> →
     `sdk/redistributable_bin/linux64/libsteam_api.so`.
2. Replace the file under `Vendor/`.
3. Check whether the accompanying notice in `Licenses/` needs updating (a
   changed licence URL, new trademark language).
4. Commit and push. Both consumers pick the new blob up on their next build.

Redistribution here relies on agreements the maintainers have accepted; see
[Vendor/README.md](../Vendor/README.md).

## Updating the FMOD blobs (SE2 archive)

`Vendor/libfmod.so.14` and `Vendor/libfmodstudio.so.14` are proprietary and
manually maintained like the blobs above — but version-locked to the game:
the FMOD wrapper inside Space Engineers 2 is generated for the FMOD version
the game ships, so the blobs must match it at least to the minor release.

1. Find the game's FMOD version:
   `strings -el "<SE2 game dir>/fmod.dll" | grep -A1 FileVersion`
2. Download that FMOD Engine version for Linux from
   <https://www.fmod.com/download> (login required).
3. Copy the two x86_64 release-variant runtimes under their SONAME file
   names — the exact paths and rules are in
   [Vendor/README.md](../Vendor/README.md). The archive names stay the bare
   `libfmod.so` / `libfmodstudio.so` regardless; if the SONAME digit changed
   (a new FMOD major/minor), update the committed file names and the copy
   step in `build.sh` together, and mention the new preload SONAME in
   [consuming.md](consuming.md#the-se2-archive).
4. Commit and push.

## Cache stamps and the CI cache

Every `Scripts/build_*.sh` computes a stamp that identifies its output — the
pin, plus the patch series or first-party source that goes into it — writes it
to `build/<dep>.stamp` on success, and skips the whole build when the stamp
and the staged files still match. CI keys its artefact cache on the same value
via `--print-stamp`, so **anything that changes the output must be reflected
in the stamp**. Bumping a pin does that automatically; so does editing a patch
series or FFmpeg's `FFMPEG_CONFIGURE_FLAGS`.

The one stamp that is **not** automatic is SDL3's `CONFIG_REV` in
`Scripts/build_sdl3.sh`: its cmake options are not hashed, so changing them
means bumping that counter by hand. Forgetting to leaves an existing build
tree — and CI's cache — serving a differently configured library.

If you add a build script, give it a stamp, a `--print-stamp` flag, and an
entry in the workflow's `CACHE_PATHS_*` block plus its restore/save pair.

## Changing the archive layout

The archive layouts are a contract with the consumers — see
[release-archive.md](release-archive.md). If you change one:

1. Update `EXPECTED_FILES` (SE1) or `EXPECTED_FILES_SE2` in `build.sh`.
2. Update the layout and file-list sections of `release-archive.md`.
3. Update both consumers' `fetch_linux_dependencies.sh` **before** merging
   here, because they will pick the new archive up on their next build with no
   opportunity to review it. Consumers that pin `LINUX_DEPENDENCIES_TAG` are
   insulated; ones that track latest are not.

Adding a file is safe. Renaming or removing one no longer strands the old copy
in a consumer's staging tree — both consumers clear the previous release's
files before extracting, see [consuming.md](consuming.md#what-the-fetch-script-does)
— but it still breaks any consumer whose expected-file list names it, so treat
it as a breaking change.

## Changing the CI runner image

`ubuntu-24.04` is pinned deliberately: it fixes the glibc the libraries link
against. Moving to a newer image raises the minimum glibc for every downstream
user, so treat it as a compatibility decision, not routine housekeeping, and
note it in the release notes.

The image name and the runner's gcc/glibc versions are part of every CI cache
key, so a bump rebuilds everything from scratch — including DXC. Expect one
very slow run after the change. The old entries are not
deleted; they age out on their own after a week unused.

## Checklist for a dependency-version pull request

* [ ] `./build.sh` succeeds from a clean tree (`--clean`)
* [ ] The dependency's stamp changed, so the CI cache is invalidated
      (`./Scripts/build_<dep>.sh --print-stamp` before and after)
* [ ] The `ldd` allow-list and `DT_RUNPATH` assertions pass
* [ ] `EXPECTED_FILES` in `build.sh` matches what was produced
* [ ] `docs/dependencies.md` version table updated
* [ ] `docs/release-archive.md` file list updated if any filename changed
* [ ] Licence texts still accurate for the new version
* [ ] Downstream impact considered (consumer expected-file lists, ABI
      changes behind unchanged bare file names)
* [ ] Draft release from the PR tested against at least one consumer
