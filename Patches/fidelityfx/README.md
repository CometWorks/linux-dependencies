# FidelityFX patch series

Patches in this directory port AMD's FidelityFX SDK to Linux and GCC so
`libamd_fidelityfx_loader_dx12.so` — the FSR 3.1.5 upscaler Space Engineers 2
P/Invokes — can be built from source. The library ships in the **SE2 archive
only**.

Unlike the other series, this one spans two upstream checkouts, so it is
split into two subdirectories and
[Scripts/build_fidelityfx.sh](../../Scripts/build_fidelityfx.sh) applies each
to its own tree:

| Directory | Applied to | Pin |
| --- | --- | --- |
| `sdk/` | The FidelityFX SDK itself | `FIDELITYFX_TAG` = `v2.3.0` |
| `ffx-sc/` | `sdk/tools/ffx_shader_compiler/`, the source of the FidelityFX_SC shader permutation compiler | `FFX_SC_TAG` = `v1.1.4` |

The 2.x releases ship FidelityFX_SC only as a prebuilt Windows `.exe`, and the
shader permutation headers it generates are what the upscaler's shader blob
tables are compiled from — so the last release that published its source is
checked out separately and ported alongside the SDK. Every command-line flag
v2.3.0's `BuildFSR3UpscalerShaders.bat` passes exists in the 1.1.4 sources.

The application rules are otherwise the same as for the other series:
`*.patch` files applied with `git apply` in byte-wise filename order within
each subdirectory, series hash in the cache stamp, a failing patch fails the
build.

## sdk/

| Patch | Changes |
| --- | --- |
| `0001-add-linux-build-support-files.patch` | Adds the five files this port needs and upstream has no equivalent of. `api/internal/ffx_linux_compat.h` is force-included into every translation unit and supplies the MSVC-only CRT functions the SDK calls (`sprintf_s`, `swprintf_s`, `wcscpy_s`, `strncpy_s`, `getenv_s`, `_countof`). `backend/dx12/ffx_dx12_helpers.h` replaces the six `CD3DX12_*` helpers `ffx_dx12.cpp` uses out of Microsoft's MSVC-only `d3dx12.h`, and adds the wide-string conversions described under `0003`. `api/internal/ffx_providers_linux.cpp` defines `GetProvider()`/`GetProviderVersions()`, which `ffx_provider.h` declares but leaves for each shipping loader DLL to define with its own provider list — the open-source tree contains no such file; here the list is FSR 3.1.5 alone. `amdinternal/api/internal/{git_hash_branch.h,ffx_watermark.h}` stand in for two headers AMD generates or keeps in its closed tree; the watermark is a debug overlay drawn only when `MLSR-WATERMARK` is set in the environment, and the stub renders nothing. |
| `0002-portability-fixes.patch` | `ffx_api.h`: `__declspec(dllexport)` on the five entry points becomes `__attribute__((visibility("default")))`, which is what exports them out of a library compiled with `-fvisibility=hidden`. `ffx_internal_types.h`: doubles `FFX_SDK_DEFAULT_CONTEXT_SIZE` on non-Windows. Every fixed-size name field inside the private effect contexts is `wchar_t[]`, and Linux `wchar_t` is 4 bytes rather than the 2 bytes upstream budgeted for, which pushes `FfxFsr3UpscalerContext_Private` (819 KB) past the 512 KB the upstream size reserves and trips a static assertion. `ffx_provider_fsr3upscale.cpp`: the MSVC-only `ui64` integer suffix becomes `ULL`. `ffx_assert.cpp` and `ffx_message.cpp`: both report through `OutputDebugString` inside `_WIN32`/`_WINDOWS` guards and do nothing at all otherwise, which would leave this port with no diagnostics; the non-Windows path now prints the same text to stderr. |
| `0003-dx12-backend-on-vkd3d-proton.patch` | The DirectX 12 backend. `ENABLE_AGS` and `ENABLE_PIX_CAPTURES` are switched off (both `LoadLibraryW` Windows-only tracing DLLs, and PIX also needs `<pix3.h>`), which required turning their `#if defined(...)` guards into `#if ...`. `D3D12SerializeRootSignature` was resolved with `GetModuleHandleW(L"D3D12.dll")`; it is now `dlopen`/`dlsym` against `libvkd3d-proton-d3d12.so`, which exports it — `RTLD_NOLOAD` first, so the reference is to the caller's already-loaded instance rather than a second private copy. `FormatMessageW`/`MessageBoxW` in the failure path become an HRESULT message through the SDK's own reporting. `WideCharToMultiByte`/`MultiByteToWideChar` become local conversions. Six `SetName` calls pass `wchar_t` strings straight into the D3D12 ABI, whose `WCHAR` is the 2-byte Windows wire type; they now convert. The unused DXGI factory — created and released again with nothing in between — is dropped rather than pulling DXVK's `CreateDXGIFactory2` into this library. The vestigial `<codecvt>`, `<memoryapi.h>` and `d3dx12.h` includes are removed; nothing in the file used the first two. |

## ffx-sc/

| Patch | Changes |
| --- | --- |
| `0001-port-the-shader-compiler-to-linux.patch` | Ports FidelityFX_SC to Linux, keeping only the HLSL path through DXC: the GLSL/glslangValidator backend, the FXC backend, the GDK console backends and the Agility SDK export are dropped, and with them the `tiny-process-library` and SPIRV-Reflect dependencies. `pch.hpp` drops `<Windows.h>`, `<atlcomcli.h>` and `<d3dcompiler.h>` in favour of DXC's own `WinAdapter.h`, which supplies `HRESULT`, `GUID`, `CComPtr` and `IID_PPV_ARGS` on Linux, plus DirectX-Headers' `d3d12shader.h` for reflection. `utils.cpp` replaces `MultiByteToWideChar`/`WideCharToMultiByte` with plain UTF-8 encode/decode — glibc `wchar_t` is UTF-32, so no locale is involved. `ffx_sc.cpp` replaces the `PathCch*` family and `_wfopen_s` with `std::filesystem` and `fopen`, and `wmain` with a `main` that widens `argv`. `hlsl_compiler.cpp` swaps `LoadLibrary`/`GetProcAddress` for `dlopen`/`dlsym` on `libdxcompiler.so`, drops the MSVC-only qualified-name-in-class-definition syntax, and renames `IDxcBlobUtf16` to `IDxcBlobWide` (upstream DXC renamed it). It also emits the `entryName` field in the generated permutation headers: SDK 2.x expects it and the 1.1.4 compiler predates it. |

## Licensing

Every source file this build compiles — all 107 under
`Kits/FidelityFX/api/`, `Kits/FidelityFX/backend/dx12/` and
`Kits/FidelityFX/upscalers/` — is named in the exception list of the SDK's own
`docs/license.md` and is therefore MIT-licensed rather than covered by the
SDK's default binary-redistribution terms. The SE2 archive ships
`LICENSES/FidelityFX-LICENSE.txt` and `LICENSES/FidelityFX-README.txt`
alongside the binary, and this directory (published with the repo) is the
corresponding source of the modifications.
