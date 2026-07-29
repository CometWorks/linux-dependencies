# Vendor blobs

This directory contains the **proprietary** native libraries that this repo
ships inside its release archive. They are committed here instead of being
downloaded by the build pipeline because their distribution requires
accepting per-vendor agreements that the maintainer has signed once, and the
upstream download endpoints are gated behind logged-in partner portals (no
public artifact URL exists).

Updating these blobs is a manual maintainer task: download the latest SDK
from the vendor portal, replace the file here, commit, push. The next push
to `main` publishes a release containing the updated blob.

## Contents

### `libEOSSDK-Linux-Shipping.so`

The Linux x86_64 runtime of the **Epic Online Services SDK**.

* Source: <https://dev.epicgames.com/portal/> -> your product ->
  SDK Downloads -> "EOS SDK for C" -> Linux build.
* License: proprietary (Epic Online Services SDK License Agreement).
  Attribution: see [Licenses/EOS-NOTICE.txt](../Licenses/EOS-NOTICE.txt).
* Used to interoperate with Space Engineers' existing EOS integration. No
  EOS SDK source code is included; only the unmodified shipping `.so` is
  redistributed.

### `libsteam_api.so`

The Linux x86_64 runtime of the **Steamworks SDK**.

* Source: <https://partner.steamgames.com/downloads/list> -> Steamworks SDK
  (`sdk/redistributable_bin/linux64/libsteam_api.so`).
* License: proprietary (Steamworks SDK Access Agreement).
  Attribution: see [Licenses/Steam-NOTICE.txt](../Licenses/Steam-NOTICE.txt).
* Used to interoperate with Space Engineers' existing Steam integration. No
  Steamworks SDK source code is included; only the unmodified shipping `.so`
  is redistributed.

## Why these are committed (and the others are not)

The remaining libraries in the release archive (FFmpeg, DXVK, Steamworks.NET)
are built from source by the scripts under [Scripts/](../Scripts/) and
therefore do not need to be committed. EOS and Steamworks have no public
source and no publicly-fetchable binary, so this directory is the only
practical place for them.

The native wrapper libraries (`libD3DCompiler.so`, `libHavok.so`,
`libRecastDetour.so`, `libVRageNative.so`) are **not** part of this repo at
all — they are built and released by
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers)
and consumers fetch them from there directly.
