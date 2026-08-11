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
3. On a SOVERSION change, update **all** of these together:
   * `EXPECTED_SOVER` in `Scripts/build_ffmpeg.sh`
   * `EXPECTED_FILES` in `build.sh` (the fully-versioned filenames too)
   * the file list in [release-archive.md](release-archive.md)
   * the version table in `Licenses/FFmpeg-README.txt`
   * **Pulsar's `LibraryVersionMap`** in
     `ClientPlugin/Audio/MySdlAudioInterop.cs` — FFmpeg.AutoGen resolves the
     libraries by SOVERSION, so a mismatch is a runtime
     `DllNotFoundException`, not a build error.
4. Check the `ldd` allow-list still passes. A new upstream release sometimes
   enables something by default that the disable list did not anticipate.
5. Confirm the FFmpeg.AutoGen version Pulsar uses still matches the FFmpeg
   major version.

The full-version filenames (`libavcodec.so.62.28.100`) change on almost every
FFmpeg release even when the SOVERSION does not, so expect step 3's file lists
to need editing regardless.

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

## Changing a patch series

Add, edit or remove `Patches/<dep>/NNNN-*.patch` files; each series' hash is
part of its dependency's cache stamp, so the next build rebuilds that
dependency automatically. Patched libraries ship **in both archives** (built
once, copied), so a patch change affects SE1 and SE2 consumers alike — test
accordingly. For every patch, record in the series' README.md what it fixes
and where it came from. Patches are applied with `git apply` in byte-wise
filename order.

## Bumping SDL3

SDL3 is not shipped — it only supplies headers for the DXVK build. Set
`SDL3_VERSION` in `Scripts/build_sdl3.sh` (the upstream tag is
`release-$SDL3_VERSION`) and rebuild DXVK.

A bump is usually only needed when a newer DXVK requires newer SDL3 headers.
Because DXVK dlopens `libSDL3.so.0` at runtime rather than linking it, the
version built here does not constrain what users need installed — but building
against much newer headers than the SDL3 in the wild is still worth avoiding.

## Bumping OpenAL Soft

1. Set `OPENAL_VERSION` **and** `OPENAL_SHA256` in `Scripts/build_openal.sh`.
   The tarball URL is mutable, so the checksum is the pin — a version bump
   without a matching checksum fails the download verification, by design.
2. Build. If upstream bumps the SONAME past `libopenal.so.1`, the script fails
   with an explicit message; update `EXPECTED_SONAME` there, `EXPECTED_FILES`
   in `build.sh`, the file list in `release-archive.md`, and Pulsar's
   expected-file lists and `/app/lib` symlink together. Silk.NET dlopens by
   SONAME, so a mismatch means the bundled library is silently unused.
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
   [Vendor/README.md](../Vendor/README.md). If the SONAME digit changed
   (a new FMOD major/minor), update the copy step and `EXPECTED_FILES_SE2`
   in `build.sh` and the file list in `release-archive.md` together.
4. Commit and push.

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

## Checklist for a dependency-version pull request

* [ ] `./build.sh` succeeds from a clean tree (`--clean`)
* [ ] The `ldd` allow-list and `DT_RUNPATH` assertions pass
* [ ] `EXPECTED_FILES` in `build.sh` matches what was produced
* [ ] `docs/dependencies.md` version table updated
* [ ] `docs/release-archive.md` file list updated if any filename changed
* [ ] Licence texts still accurate for the new version
* [ ] Downstream impact considered (Pulsar's `LibraryVersionMap`, Magnetar's
      expected files)
* [ ] Draft release from the PR tested against at least one consumer
