# DXVK patch series for the Space Engineers 2 build

Patches in this directory are applied on top of the pinned upstream DXVK tag
(see `DXVK_VERSION` in [Scripts/build_dxvk.sh](../../Scripts/build_dxvk.sh))
before building the **SE2 variant** of `libdxvk_d3d11.so` / `libdxvk_dxgi.so`.
The SE1 variant is always built from pristine upstream sources and is not
affected by anything here.

These are source-level fixes for DXVK bugs that the Space Engineers 2 client
hits; fixing them here replaces what would otherwise be a much larger set of
managed (Harmony) runtime patches in the SE2 Linux compatibility layer.

## How the series is applied

* Files matching `*.patch` are applied with `git apply`, in byte-wise
  (`LC_ALL=C`) filename order. Name them `NNNN-short-title.patch`
  (`0001-...`, `0002-...`) so the order is explicit.
* The series hash is part of the build cache key: adding, editing or removing
  a patch automatically invalidates `build/dxvk-se2.stamp` and triggers a
  rebuild of the SE2 variant only.
* A patch that fails to apply fails the build with an error naming the patch.
  That is the signal that a `DXVK_VERSION` bump needs the series rebased —
  see [docs/maintenance.md](../../docs/maintenance.md).
* An empty series is valid: the SE2 variant is then built from pristine
  upstream sources (still staged and shipped separately).

## Provenance

Record for every patch where it came from, so the series can be refreshed:

| Patch | Fixes | Source (repo @ commit) |
| --- | --- | --- |
| *(none yet — the series from the SE2 repo has not been imported)* | | |

## Licensing

DXVK is zlib-licensed; modified builds may be distributed under the same
terms. The archive ships `LICENSES/DXVK-LICENSE.txt` alongside the patched
binaries, and this directory (published with the repo) is the corresponding
source of the modifications.
