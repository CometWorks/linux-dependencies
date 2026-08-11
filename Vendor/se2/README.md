# SE2 vendor blobs

This directory holds the binary-only native libraries of the Space Engineers 2
client's Linux port, shipped in the `linux-dependencies-se2.tar.gz` release
archive. Like the EOS and Steamworks blobs one level up, they are committed
because no publicly fetchable artifact URL exists for them.

## Contents

### FMOD Engine runtime (proprietary, Firelight Technologies)

| File | What it is |
| --- | --- |
| `libfmod.so.14` | FMOD Core API runtime, Linux x86_64 |
| `libfmodstudio.so.14` | FMOD Studio API runtime, Linux x86_64 |

* Source: <https://www.fmod.com/download> (login required) → FMOD Engine →
  Linux → version **2.03.11**, matching the FMOD the game ships (verified
  against the `FileVersion` resource of the game's `fmod.dll`:
  2.03.11 build 158528). The file names carry the upstream SONAMEs
  (`libfmod.so.14`), exactly as the SE2 port consumes them.
* Release variants, **not** the `L` (logging) builds.
* License: proprietary; redistribution of the unmodified runtime is permitted
  by the FMOD EULA. Shipped alongside as `LICENSES/FMOD-EULA.txt` and
  `LICENSES/FMOD-NOTICE.txt`.
* **Version rule:** the FMOD API is version-locked — the managed wrapper
  inside SE2 is generated for the game's FMOD version, so these blobs must
  match it at least to the minor release. When the game updates its FMOD,
  update these in lockstep (see docs/maintenance.md).

### SE2 native wrappers (MIT, CometWorks)

| File | Wraps |
| --- | --- |
| `libVRage.KytheraV2.Native.so` | Kythera AI |
| `libVRage.Physics.Native.so` | Havok physics |
| `libVRage.Slug.Native.so` | Slug text rendering |
| `libVRage.Voxels.Native.so` | Voxel mesh/tailor |

Linux wrapper builds of the game's Keen-built native DLL surface, built from
the `linux-native-wrappers` sister repository (SE2 support landed with
commits `14f3349`, `cf7edec` and `9577d72`). Committed here as blobs — taken
from the SE2 port's tested `NativeLibs/` set — rather than fetched from a
wrappers release, because no SE2 wrapper release exists yet; when the
wrappers repo starts publishing SE2 builds, these should switch to that
release and leave this directory. License: MIT, shipped as
`LICENSES/linux-native-wrappers-MIT.txt`.

## Updating

Replace the file(s), commit, push. `build.sh` copies them into the SE2
staging tree verbatim (the file names already carry the SONAMEs, so no alias
symlinks are derived).
