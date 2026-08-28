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
| `0001-dxgi-windows-abi-16-bit-wchar.patch` | `WCHAR` is 32-bit `wchar_t` on the native build, so `IDXGIAdapter::GetDesc*` / `IDXGIOutput::GetDesc` write a 560-byte structure into the caller's 304-byte Windows-ABI buffer, corrupting managed memory (Vortice/SharpDX marshal with 16-bit `WCHAR`). The patch makes `WCHAR` 16-bit, transcodes the SDL display name at the WSI boundary, rewrites the two `CreateSharedHandle` implementations (D3D11 resource and fence) off the `wchar_t`-typed `wcslen`/`swprintf` onto DXVK's own `str::length`/`str::transcodeString`, and adds compile-time asserts for the Windows x64 sizes of `DXGI_ADAPTER_DESC` (304), `DXGI_ADAPTER_DESC1` (312), `DXGI_ADAPTER_DESC3` (320) and `DXGI_OUTPUT_DESC` (96). | Reimplementation of the fix described in `dotnet-game2-local` Finding 012 (their dedicated DXVK checkout, commit `d592777f`, was not preserved); originally authored against v2.7.1 and verified with a raw-vtable `GetDesc` guard-word test. Rebased onto v3.0.2 (2026-08): upstream dropped the duplicate `LPWSTR` typedef from `windows_base.h`, and the shared-NT-handle naming code added in 3.0 needed the `wcslen`/`swprintf` rewrite to compile with a 16-bit `WCHAR`. |
| `0002-d3d11-use-new-surface-extent.patch` | `D3D11SwapChain::ChangeProperties` detects a resize by comparing the old descriptor (`m_desc`) with the new one (`pDesc`), but passes the **old** extent to `Presenter::setSurfaceExtent` — `m_desc = *pDesc` runs only afterwards. The Vulkan presenter therefore lags one resize behind the D3D11 backbuffers; after an `A -> B -> C` window resize the backbuffer is at C while the presentation image is at B, and the swapchain blitter's linear scaling blurs the whole frame until restart. The one-line fix passes `pDesc`'s extent, keeping the recreation condition unchanged. Safe because `DxgiSwapChain::ResizeBuffers1` resolves zero dimensions from the window size before calling in, and surfaces with a fixed `currentExtent` ignore the preferred extent anyway. The D3D9 path is unaffected (it refreshes the extent from the window before presenting). | Found while fixing blurry-after-resize rendering in Space Engineers on Linux (`se1/linux-compat`, D3D11 resize work). Introduced upstream by [`43838d3d`](https://github.com/doitsujin/dxvk/commit/43838d3df8c1e5e1d3ec1f69413598b7ff296c6e), which moved Vulkan swapchain management into the presenter backend; still present upstream when investigated (2026-08). Authored against v2.7.1; verified with ordered resize traces on KDE Plasma Wayland (fractional scaling) and `SDL_VIDEODRIVER=x11` — renderer and DXVK presenter extents stay synchronized and the image stays sharp. Still unfixed in v3.0.2, where the patch applies unchanged. Submit upstream, and drop this patch once the pinned tag contains the fix. |
| `0003-dxbc-spirv-select-nonzero-divisor.patch` | DXBC defines both results of unsigned division by zero as all bits set (`0xffffffff`), but `Converter::handleIntDivide` in the `dxbc-spirv` subproject emitted `OpUDiv`/`OpUMod` with the original divisor and only fixed the result up with a later `OpSelect`. SPIR-V leaves the zero-divisor operation itself undefined, and the `OpSelect` does not retroactively make it valid — on the NVIDIA Vulkan driver the undefined result leaked through. Space Engineers hits this in `Content/Shaders/Foliage/Foliage.hlsl`: `GetSkip` uses integer remainder to choose which foliage primitives to skip, and the undefined `OpUMod` result inverted the grass LOD pattern (no grass near the player, grass beyond a sharp circular boundary). The patch selects a nonzero divisor (`neg1` when `den == 0`) before emitting `OpUDiv`/`OpUMod` and keeps the existing result selection, so DXBC semantics are unchanged and the SPIR-V is defined for every divisor. | Root-caused in `se1/Bugs/FixDxvkDivByZeroGrassIssue.md` (2026-08) with SE 1.210.014, an RTX 4070 and NVIDIA driver 610.57.4: removing render-stage distance logic restored nearby grass, and narrowing that to `GetSkip` exposed the zero-divisor `OpUMod` in the translated SPIR-V. Verified there against the original game shaders (grass renders without the circular gap), with `spirv-val` on the dumped foliage geometry shader, and with the dxbc-spirv converter tests (`dxbc-spirv:enable_tests=true`, 199,608 checks passing). Authored against the dxbc-spirv submodule pinned by DXVK v3.0.2 (`887bb6c`). Applies to the shared DXBC converter rather than the one game shader so every DXBC shader gets defined division. Submit upstream to `doitsujin/dxbc-spirv`, and drop this patch once the pinned submodule contains the fix. |

## Licensing

DXVK is zlib-licensed; modified builds may be distributed under the same
terms. The archive ships `LICENSES/DXVK-LICENSE.txt` alongside the patched
binaries, and this directory (published with the repo) is the corresponding
source of the modifications.
