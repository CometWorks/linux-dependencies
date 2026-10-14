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

Record for every patch where it came from, so the series can be refreshed.
The numbering has a gap: `0003-dxbc-spirv-select-nonzero-divisor.patch`
(zero-divisor `OpUDiv`/`OpUMod`, which inverted the SE1 grass LOD on NVIDIA)
was dropped on the bump to v3.1.1, whose dxbc-spirv pin `bf14419` has
upstream's own fix (`213d2b8`, moved to `ArithmeticPass::lowerUDiv` in
`304a708`). Its root-cause analysis is in the git history of this file.

| Patch | Fixes | Source |
| --- | --- | --- |
| `0001-dxgi-windows-abi-16-bit-wchar.patch` | `WCHAR` is 32-bit `wchar_t` on the native build, so `IDXGIAdapter::GetDesc*` / `IDXGIOutput::GetDesc` write a 560-byte structure into the caller's 304-byte Windows-ABI buffer, corrupting managed memory (Vortice/SharpDX marshal with 16-bit `WCHAR`). The patch makes `WCHAR` 16-bit, transcodes the SDL display name at the WSI boundary, rewrites the two `CreateSharedHandle` implementations (D3D11 resource and fence) off the `wchar_t`-typed `wcslen`/`swprintf` onto DXVK's own `str::length`/`str::transcodeString`, and adds compile-time asserts for the Windows x64 sizes of `DXGI_ADAPTER_DESC` (304), `DXGI_ADAPTER_DESC1` (312), `DXGI_ADAPTER_DESC3` (320) and `DXGI_OUTPUT_DESC` (96). | Reimplementation of the fix described in `dotnet-game2-local` Finding 012 (their dedicated DXVK checkout, commit `d592777f`, was not preserved); originally authored against v2.7.1 and verified with a raw-vtable `GetDesc` guard-word test. Rebased onto v3.0.2 (2026-08): upstream dropped the duplicate `LPWSTR` typedef from `windows_base.h`, and the shared-NT-handle naming code added in 3.0 needed the `wcslen`/`swprintf` rewrite to compile with a 16-bit `WCHAR`. Applies unchanged on v3.1.1 (2026-10). Upstream issue: [doitsujin/dxvk#5566](https://github.com/doitsujin/dxvk/issues/5566). |
| `0002-d3d11-use-new-surface-extent.patch` | `D3D11SwapChain::ChangeProperties` detects a resize by comparing the old descriptor (`m_desc`) with the new one (`pDesc`), but passes the **old** extent to `Presenter::setSurfaceExtent` — `m_desc = *pDesc` runs only afterwards. The Vulkan presenter therefore lags one resize behind the D3D11 backbuffers; after an `A -> B -> C` window resize the backbuffer is at C while the presentation image is at B, and the swapchain blitter's linear scaling blurs the whole frame until restart. The one-line fix passes `pDesc`'s extent, keeping the recreation condition unchanged. Safe because `DxgiSwapChain::ResizeBuffers1` resolves zero dimensions from the window size before calling in, and surfaces with a fixed `currentExtent` ignore the preferred extent anyway. The D3D9 path is unaffected (it refreshes the extent from the window before presenting). | Found while fixing blurry-after-resize rendering in Space Engineers on Linux (`se1/linux-compat`, D3D11 resize work). Introduced upstream by [`43838d3d`](https://github.com/doitsujin/dxvk/commit/43838d3df8c1e5e1d3ec1f69413598b7ff296c6e), which moved Vulkan swapchain management into the presenter backend; still present upstream when investigated (2026-08). Authored against v2.7.1; verified with ordered resize traces on KDE Plasma Wayland (fractional scaling) and `SDL_VIDEODRIVER=x11` — renderer and DXVK presenter extents stay synchronized and the image stays sharp. Still unfixed in v3.0.2 and v3.1.1, where the patch applies unchanged. Upstream fixed it in [`3dbf33c`](https://github.com/doitsujin/dxvk/commit/3dbf33c) (2026-09-25), which is newer than v3.1.1; drop this patch on the first bump to a release that contains it. |
| `0004-openxr-vulkan-external-fd-extensions.patch` | DXVK Native never enables what an OpenXR runtime needs to take its Vulkan device: the OpenXR/OpenVR extension providers in `dxvk_instance.cpp` sit under `#ifdef _WIN32`. WiVRn 26.9 (`xrGetVulkanInstanceExtensionsKHR` / `xrGetVulkanDeviceExtensionsKHR`) asks for device `VK_KHR_external_memory_fd`, `VK_KHR_external_semaphore_fd`, `VK_KHR_external_fence_fd` and instance `VK_KHR_get_physical_device_properties2` plus the external memory/semaphore/fence capabilities. The instance ones are core in Vulkan 1.1, but the runtime looks up their KHR-named entry points (`vkGetPhysicalDeviceProperties2KHR` and others), which the loader returns as null unless the extension is enabled, and calls them unchecked: `xrGetVulkanGraphicsDeviceKHR` jumps to address 0 on the render thread. The patch has the platform WSI provider enable the four instance extensions and, per adapter, each of the three `_fd` device extensions the adapter supports, all inside `#ifndef _WIN32` (the Windows build is unchanged). | Found bringing up the Space Engineers VR plugin (OpenXR, `XR_KHR_vulkan_enable` on DXVK's own VkInstance/VkDevice via `IDXGIVkInteropDevice`) under native Linux Pulsar with WiVRn 26.9 and a Quest 3, Ubuntu 26.04, RTX 3060 (2026-10). Verified with gdb on `vkCreateDevice` (42 device extensions stock, 45 patched, the three `_fd` present) and in game: stock DXVK crashes in `libopenxr_wivrn.so`, patched creates the session and streams to the headset; `D3D11CreateDevice` succeeds both ways; the MinGW Windows build compiles. Authored against v3.0.2; applies unchanged on v3.1.1, after 0001 and 0002. A candidate for upstream as an opt-in (any OpenXR/OpenVR app on DXVK Native needs it). |

## Licensing

DXVK is zlib-licensed; modified builds may be distributed under the same
terms. The archive ships `LICENSES/DXVK-LICENSE.txt` alongside the patched
binaries, and this directory (published with the repo) is the corresponding
source of the modifications.
