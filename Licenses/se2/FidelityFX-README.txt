AMD FidelityFX build provenance
===============================

The shared library shipped alongside this notice as:

    libamd_fidelityfx_loader_dx12.so

is built from source by Scripts/build_fidelityfx.sh of the
CometWorks/linux-dependencies repository:

    https://github.com/CometWorks/linux-dependencies

libamd_fidelityfx_loader_dx12.so
--------------------------------
Upstream:   https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK
Tag:        v2.3.0
Commit:     60f4ea81909200d8542eca14dccb2628b763a9a3

The library implements AMD's flat "ffx_api" ABI — ffxCreateContext,
ffxDestroyContext, ffxConfigure, ffxQuery and ffxDispatch — which is what
Space Engineers 2 P/Invokes from "amd_fidelityfx_loader_dx12.dll" when FSR
upscaling is selected. The ffx_api dispatcher, the DirectX 12 backend and the
FSR 3.1.5 upscaler provider are linked into this single object, so no separate
provider library is loaded at run time.

FSR 3.1.5 is the only upscaler included. FSR 4.x is distributed as a prebuilt,
signed Windows DLL with no source, and the driver-side provider lives in AMD's
closed "amdinternal" tree, so neither can be part of a from-source build. The
DirectX 12 backend is compiled against vkd3d-proton's headers, and the
ID3D12Device and ID3D12Resource pointers the caller passes are vkd3d-proton's
own.

The Patches/fidelityfx/ series is applied before the build. It ports the SDK
to Linux and GCC: MSVC-only CRT calls, Win32 diagnostics, the AGS and PIX
tracing paths, the MSVC-only d3dx12.h helpers, and the 2-byte/4-byte wchar_t
mismatch between the platform and the D3D12 ABI. See Patches/fidelityfx/
README.md in the repository above for the file-by-file rationale.

Shaders
-------
The FSR 3.1 compute passes are compiled to DXIL during the build by
FidelityFX_SC, AMD's shader permutation compiler, itself ported to Linux from
FidelityFX SDK v1.1.4 (the 2.x releases ship it only as a Windows binary). It
drives a stock, unpatched build of the same DirectX Shader Compiler release
that produces the libdxcompiler.so in this archive. The resulting DXIL is
unsigned; vkd3d-proton does not validate DXIL signatures. Neither the shader
compiler nor that DXC build is part of this archive.

License
-------
MIT — see FidelityFX-LICENSE.txt next to this file.

Rebuilding
----------
Rebuild with Scripts/build_fidelityfx.sh (or an equivalent build of the same
patched sources) and substitute the resulting library.
