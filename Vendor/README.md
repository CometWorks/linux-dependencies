# Vendor blobs

This directory contains the **proprietary** native libraries that this repo
ships inside its release archives. They are committed here instead of being
downloaded by the build pipeline because their distribution requires
accepting per-vendor agreements that the maintainer has signed once, and the
upstream download endpoints are gated behind logged-in partner portals (no
public artifact URL exists).

Updating these blobs is a manual maintainer task: download the latest SDK
from the vendor portal, replace the file here, commit, push. The next push
to `main` publishes a release containing the updated blob.

## Contents

### `libEOSSDK-Linux-Shipping.so`

The Linux x86_64 runtime of the **Epic Online Services SDK**. Ships in the
SE1 archive.

* Source: <https://dev.epicgames.com/portal/> -> your product ->
  SDK Downloads -> "EOS SDK for C" -> Linux build.
* License: proprietary (Epic Online Services SDK License Agreement).
  Attribution: see [Licenses/EOS-NOTICE.txt](../Licenses/EOS-NOTICE.txt).
* Used to interoperate with Space Engineers' existing EOS integration. No
  EOS SDK source code is included; only the unmodified shipping `.so` is
  redistributed.

### `libsteam_api.so`

The Linux x86_64 runtime of the **Steamworks SDK**. Ships in the SE1 archive.

* Source: <https://partner.steamgames.com/downloads/list> -> Steamworks SDK
  (`sdk/redistributable_bin/linux64/libsteam_api.so`).
* License: proprietary (Steamworks SDK Access Agreement).
  Attribution: see [Licenses/Steam-NOTICE.txt](../Licenses/Steam-NOTICE.txt).
* Used to interoperate with Space Engineers' existing Steam integration. No
  Steamworks SDK source code is included; only the unmodified shipping `.so`
  is redistributed.

### `libfmod.so.14` and `libfmodstudio.so.14`

The Linux x86_64 runtimes of the **FMOD Engine** (Core and Studio APIs).
Ship in the SE2 archive only — Space Engineers 1 does not use FMOD.

* Source: <https://www.fmod.com/download> (login required) -> FMOD Engine ->
  Linux -> version **2.03.11**, matching the FMOD the game ships (verified
  against the `FileVersion` resource of the game's `fmod.dll`:
  2.03.11 build 158528). The file names carry the upstream SONAMEs
  (`libfmod.so.14`), exactly as the SE2 port consumes them. Release
  variants, **not** the `L` (logging) builds.
* License: proprietary; redistribution of the unmodified runtime is
  permitted by the FMOD EULA. Shipped alongside as `LICENSES/FMOD-EULA.txt`
  and `LICENSES/FMOD-NOTICE.txt` (sources under
  [Licenses/se2/](../Licenses/se2/)).
* **Version rule:** the FMOD API is version-locked — the managed wrapper
  inside SE2 is generated for the game's FMOD version, so these blobs must
  match it at least to the minor release. When the game updates its FMOD,
  update these in lockstep; if the SONAME digit changes, update `build.sh`
  (the copy step and `EXPECTED_FILES_SE2`) and `docs/release-archive.md`
  together. See [docs/maintenance.md](../docs/maintenance.md).

## Why these are committed (and the others are not)

The remaining libraries in the release archives (FFmpeg, DXVK, vkd3d-proton,
OpenAL, Steamworks.NET) are built from source by the scripts under
[Scripts/](../Scripts/) and therefore do not need to be committed. EOS,
Steamworks and FMOD have no public source and no publicly-fetchable binary,
so this directory is the only practical place for them.

The native wrapper libraries — SE1's `libD3DCompiler.so`, `libHavok.so`,
`libRecastDetour.so`, `libVRageNative.so`, and SE2's `libVRage.*.Native.so`
set — are **not** part of this repo at all: they are built and released by
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers)
and consumers fetch them from there directly.
