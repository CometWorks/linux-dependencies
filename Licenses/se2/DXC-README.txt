DirectX Shader Compiler build provenance
========================================

The shared library shipped alongside this notice as:

    libdxcompiler.so        the patched DirectX Shader Compiler

is built from source by Scripts/build_dxc.sh of the
CometWorks/linux-dependencies repository:

    https://github.com/CometWorks/linux-dependencies

libdxcompiler.so
----------------
Upstream:   https://github.com/microsoft/DirectXShaderCompiler
Tag:        v1.9.2607
Commit:     0d3ee6b551b8fa768fbf825300ebab81047ef6a8

The Patches/dxc/ series is applied before a release build with assertions off
and the test suites excluded. It converts strings at DXC's public compiler,
result and include-handler boundaries because Vortice.Dxc uses Windows 2-byte
WCHAR strings while native Linux DXC uses 4-byte wchar_t. Because the library
is compiled rather than taken from an upstream release download, no Microsoft
binary distribution agreement applies to it — only the source licence below.

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
Rebuild with Scripts/build_dxc.sh (or an equivalent build of the same patched
sources) and substitute the resulting library.
