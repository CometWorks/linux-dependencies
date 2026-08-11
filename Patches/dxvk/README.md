# DXVK patch series

Patches in this directory are applied on top of the pinned upstream DXVK tag
(see `DXVK_VERSION` in [Scripts/build_dxvk.sh](../../Scripts/build_dxvk.sh))
before building `libdxvk_d3d11.so` / `libdxvk_dxgi.so`. DXVK is built **once**
with the series applied, and the same binaries ship in both release archives
(SE1 and SE2).

These are source-level fixes for DXVK bugs that the Space Engineers clients
hit; fixing them here replaces what would otherwise be a much larger set of
managed (Harmony) runtime patches in the Linux compatibility layers.

## How the series is applied

* Files matching `*.patch` are applied with `git apply`, in byte-wise
  (`LC_ALL=C`) filename order. Name them `NNNN-short-title.patch`
  (`0001-...`, `0002-...`) so the order is explicit.
* The series hash is part of the build cache key: adding, editing or removing
  a patch automatically invalidates `build/dxvk.stamp` and triggers a rebuild.
* A patch that fails to apply fails the build with an error naming the patch.
  That is the signal that a `DXVK_VERSION` bump needs the series rebased —
  see [docs/maintenance.md](../../docs/maintenance.md).
* An empty series is valid: the build is then pristine upstream.

## Provenance

Record for every patch where it came from, so the series can be refreshed:

| Patch | Fixes | Source |
| --- | --- | --- |
| `0001-dxgi-windows-abi-16-bit-wchar.patch` | `WCHAR` is 32-bit `wchar_t` on the native build, so `IDXGIAdapter::GetDesc*` / `IDXGIOutput::GetDesc` write a 560-byte structure into the caller's 304-byte Windows-ABI buffer, corrupting managed memory (Vortice/SharpDX marshal with 16-bit `WCHAR`). The patch makes `WCHAR` 16-bit, transcodes the SDL display name at the WSI boundary, and adds compile-time asserts for the Windows x64 sizes of `DXGI_ADAPTER_DESC` (304), `DXGI_ADAPTER_DESC1` (312), `DXGI_ADAPTER_DESC3` (320) and `DXGI_OUTPUT_DESC` (96). | Reimplementation of the fix described in `dotnet-game2-local` Finding 012 (their dedicated DXVK checkout, commit `d592777f`, was not preserved); authored against v2.7.1 and verified with a raw-vtable `GetDesc` guard-word test. |

## Licensing

DXVK is zlib-licensed; modified builds may be distributed under the same
terms. The archive ships `LICENSES/DXVK-LICENSE.txt` alongside the patched
binaries, and this directory (published with the repo) is the corresponding
source of the modifications.
