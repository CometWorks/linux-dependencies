# SE2 vendor blobs (FMOD)

This directory holds the **FMOD Engine** runtime libraries for the Space
Engineers 2 client, shipped in the `linux-dependencies-se2.tar.gz` release
archive. Like the EOS and Steamworks blobs one level up, they are committed
here because the upstream download is gated behind a logged-in account (no
public artifact URL exists).

## Expected files

| File | What it is |
| --- | --- |
| `libfmod.so` | FMOD Core API runtime, Linux x86_64 |
| `libfmodstudio.so` | FMOD Studio API runtime, Linux x86_64 |

Commit the **real files** under these bare names (not symlinks). `build.sh`
reads each blob's SONAME (e.g. `libfmod.so.14`) with `readelf` and stages a
matching alias symlink next to it in the archive, so `libfmodstudio.so`'s
`NEEDED` reference to `libfmod` by SONAME resolves.

**Bootstrap note:** until both files are present, `build.sh` skips packaging
the SE2 archive with a prominent warning instead of failing, so the SE1
archive keeps shipping. Committing the two blobs is what activates the SE2
release asset.

## Obtaining the blobs

1. Log in at <https://www.fmod.com/download> (free registration) and download
   **FMOD Engine** for **Linux**, version **2.03.11** — see the version rule
   below. The package is `fmodstudioapi<version>linux.tar.gz`.
2. From the extracted package copy, renaming to the bare names:
   * `api/core/lib/x86_64/libfmod.so.*` (the real file, largest/fully
     versioned one) → `libfmod.so`
   * `api/studio/lib/x86_64/libfmodstudio.so.*` (same) → `libfmodstudio.so`

   Use the release variants, **not** the `L` (logging) builds
   (`libfmodL.so` / `libfmodstudioL.so`).
3. Commit. The `.gitignore` has a `!Vendor/se2/*.so` exception for exactly
   these files.

## Version rule

The FMOD API is version-locked: the managed wrapper inside SE2 was generated
for the FMOD version the game ships, so **these blobs must match the game's
FMOD version at least to the minor release**. Check the game's version with:

```bash
strings -el "<SE2 game dir>/fmod.dll" | grep -A1 FileVersion
```

As of SE2 2.3.0.x that is **2.03.11 (build 158528)** — FMOD writes it
`2.3.11` in the PE resource — for both `fmod.dll` and `fmodstudio.dll`.
When the game updates its FMOD, update these blobs in lockstep; see
[docs/maintenance.md](../../docs/maintenance.md).

## Licensing

Proprietary (Firelight Technologies). The FMOD End User License Agreement
permits redistributing the unmodified runtime libraries as part of a product;
attribution ships in the archive as `LICENSES/FMOD-NOTICE.txt` (source:
[Licenses/se2/FMOD-NOTICE.txt](../../Licenses/se2/FMOD-NOTICE.txt)).
