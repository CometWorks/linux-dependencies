# vkd3d-proton patch series

Patches in this directory are applied on top of the pinned upstream
vkd3d-proton commit (see `VKD3D_PROTON_COMMIT` in
[Scripts/build_vkd3d_proton.sh](../../Scripts/build_vkd3d_proton.sh)) before
building `libvkd3d-proton-d3d12.so` / `libvkd3d-proton-d3d12core.so`, which
ship in the **SE2 archive only** — Space Engineers 1 never shipped a D3D12
layer, and the SE1 archive's library set stays as it was.

The application rules are the same as for [Patches/dxvk/](../dxvk/README.md):
`*.patch` files applied with `git apply` in byte-wise filename order, series
hash in the cache stamp, a failing patch fails the build.

## Provenance

The native-dxgi and cpu-fp64 patches come from the SE2 Linux port repository
(`dotnet-game2-local/LinuxCompat/Native/`), developed and tested against
upstream commit `3dfc6f07d0953b1` — the reason the pin is that commit. The
dxbc-spirv divisor patch is this repo's DXVK patch
[`0003-dxbc-spirv-select-nonzero-divisor.patch`](../dxvk/README.md) re-rooted
onto vkd3d-proton's own vendored copy of the same converter.

| Patch | Fixes |
| --- | --- |
| `vkd3d-proton-dxbc-spirv-select-nonzero-divisor.patch` | Same defect as the DXVK series' `0003-dxbc-spirv-select-nonzero-divisor.patch`, in vkd3d-proton's own copy of the `dxbc-spirv` converter (vendored via its `dxil-spirv` subproject, at a different revision with identical `Converter::handleIntDivide` code): `OpUDiv`/`OpUMod` were emitted with a possibly-zero divisor, which SPIR-V leaves undefined even though a later `OpSelect` fixes the result up to DXBC's all-bits-set. The patch selects a nonzero divisor first, exactly as in the DXVK patch — see [Patches/dxvk/README.md](../dxvk/README.md) for the full root-cause analysis (inverted grass LOD in SE1 on the NVIDIA Vulkan driver). Applied here so SM ≤ 5 DXBC shaders reaching the D3D12 layer get defined division too. Drop together with the DXVK patch once upstream `doitsujin/dxbc-spirv` contains the fix and both pins have caught up. |
| `vkd3d-proton-native-dxgi.patch` | Native `D3D12CreateDevice` receives the DXGI adapter from managed code but does not retain it as the device parent on Linux. DXVK unconditionally asks the vkd3d swapchain presenter for that parent adapter, causing a null dereference during `CreateSwapChainForHwnd`. The patch retains the supplied adapter for DXGI identity and COM lifetime only; Vulkan physical-device selection is unchanged. |
| `vkd3d-proton-cpu-fp64.patch` | Gated by the `SE2_CPU_RENDERING` environment variable (inert otherwise): reports FP64 shader support when llvmpipe exposes `shaderFloat64` but not FP64 denorm preservation, allowing SE2's double-precision compute pipelines to compile in the CPU-rendering test harness. Must not be enabled for normal GPU rendering. |

## Licensing

vkd3d-proton is LGPL-2.1-licensed. The SE2 archive ships
`LICENSES/VKD3D-LGPL-2.1.txt` and `LICENSES/vkd3d-proton-README.txt` (build
provenance and relinking notes) alongside the binaries, and this directory
(published with the repo) is the corresponding source of the modifications.
