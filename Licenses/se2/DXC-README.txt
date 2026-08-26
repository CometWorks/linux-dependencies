DirectX Shader Compiler build provenance
========================================

The shared libraries shipped alongside this notice as:

    libdxcompiler.so        the DirectX Shader Compiler itself
    libSE2DxcCompiler.so    the ABI shim Space Engineers 2 loads in its place

are built from source by Scripts/build_dxc.sh of the
CometWorks/linux-dependencies repository:

    https://github.com/CometWorks/linux-dependencies

libdxcompiler.so
----------------
Upstream:   https://github.com/microsoft/DirectXShaderCompiler
Tag:        v1.9.2607
Commit:     0d3ee6b551b8fa768fbf825300ebab81047ef6a8

Unmodified upstream sources; no patch series is applied. The build is a
release build with assertions off and the test suites excluded. Because the
library is compiled rather than taken from an upstream release download, no
Microsoft binary distribution agreement applies to it — only the source
licence below.

License
-------
LLVM Release License (University of Illinois/NCSA Open Source License), with
portions under the MIT License and other notices — see DXC-LICENSE.txt next
to this file, which is the verbatim LICENSE.TXT of the pinned source tree.

Three further projects are statically linked into libdxcompiler.so:
SPIRV-Tools (Apache-2.0), SPIRV-Headers (Khronos/MIT-style) and
DirectX-Headers (MIT). Their licence texts are reproduced in
DXC-BUNDLED-LICENSES.txt next to this file. They are unmodified upstream
checkouts at the submodule revisions recorded by the pinned tag.

libSE2DxcCompiler.so
--------------------
First-party code, MIT-licensed with the rest of the
CometWorks/linux-dependencies repository. The source is a single file,
published at Sources/dxc-bridge/DxcCompilerBridge.cpp in that repository, and
is compiled against the headers of the exact DXC tree pinned above.

It exists because Space Engineers 2 reaches the compiler through Vortice.Dxc,
which marshals every string as the Windows 2-byte WCHAR, while a Linux DXC
build uses the 4-byte platform wchar_t. The shim forwards DxcCreateInstance
to libdxcompiler.so and converts strings across that boundary.

Notes
-----
libdxil.so is deliberately not part of this archive. The DXIL validator hash
is open source and compiled directly into libdxcompiler.so, which never
dlopens libdxil.so; containers produced with and without it present are
byte-identical, including the DXIL hash. It is also distributed only as a
prebuilt binary, so omitting it is what allows this payload to be built
entirely from source.

Rebuilding
----------
Both libraries are ordinary shared objects. To replace them, rebuild with
Scripts/build_dxc.sh (or any equivalent build of the same sources) and
substitute the resulting files.
