# SE2 DXC ABI shim

First-party source for `libSE2DxcCompiler.so`, built by
[Scripts/build_dxc.sh](../../Scripts/build_dxc.sh) and shipped in the **SE2
archive only** next to the `libdxcompiler.so` it wraps.

This is the one place in this repository where a shipped binary is compiled
from source that lives here rather than upstream, which is why it sits under
`Sources/` instead of `Patches/`.

## Why it exists

Space Engineers 2 compiles every shader through `Vortice.Dxc`, which
P/Invokes `DxcCreateInstance` from `dxcompiler.dll` and marshals all strings
as the Windows 2-byte `WCHAR`. A Linux DXC build uses the platform
`wchar_t`, which is 4 bytes. The two ABIs are incompatible at every string
argument and every string-returning interface.

The shim exports `DxcCreateInstance` and `DxcCreateInstance2`, forwards them
to the real compiler, and wraps the three interfaces that carry strings
across the boundary:

| Wrapper | Converts |
| --- | --- |
| `Compiler3` | UTF-16 command-line arguments to UTF-32 on the way in. It also filters `-WX` out of the argument list, and recomputes the source length for `DXC_CP_ACP` buffers whose caller-supplied size is not trustworthy. |
| `Result` | the UTF-32 output name `IDxcBlobWide` back to a UTF-16 one. |
| `IncludeHandler` | the UTF-16 filename the caller is asked for to UTF-32, and the UTF-16 source blob it returns to UTF-8. |

Building DXC with `-fshort-wchar` instead — so the whole library speaks
2-byte `WCHAR` and no shim is needed — does not work: `libdxcompiler.so`
imports eight wide-char functions from glibc (`wcslen`, `wcscmp`, `wcsncmp`,
`wcsncpy`, `wmemcmp`, `wmemcpy`, `mbstowcs`, `wcstombs`), and a 2-byte
`wchar_t` build would silently mismatch every one of them.

## Backend resolution

The backend is `dlopen`ed lazily on the first `DxcCreateInstance` call:

1. `$SE2_DXCOMPILER_BACKEND`, if set — an explicit path, for debugging or for
   pointing at a locally built compiler.
2. Otherwise the bare SONAME `libdxcompiler.so`, which the shim's
   `DT_RUNPATH` of `$ORIGIN` resolves to the copy staged beside it.

Resolving by name rather than by an absolute path is deliberate. An earlier
revision hardcoded `/usr/lib/libdxcompiler.so`, which picked up whatever the
host happened to have installed — in practice a v1.10 Shader Model 6.10
preview, which aborts inside LLVM while compiling SE2's Render12 shaders.

## Version coupling

The shim reimplements COM vtables by inheriting from the `IDxc*` interfaces
in `<dxc/dxcapi.h>`, so its layout is bound to the DXC version it wraps.
`build_dxc.sh` therefore compiles it against the headers of the exact DXC
tree it just built, in the same step — that coupling is the reason this
source lives in this repository rather than in a consuming one.

Bumping the DXC pin means re-checking this file against the new `dxcapi.h`:
an interface gaining a method is a silent ABI break, not a compile error.

## Building it on its own

`build_dxc.sh` does this as part of its run; the standalone form is

```bash
g++ -O2 -fPIC -shared -std=c++20 -I <dxc-source>/include \
    -o libSE2DxcCompiler.so DxcCompilerBridge.cpp -ldl -Wl,-rpath,'$ORIGIN'
```

## Licensing

MIT, with the rest of this repository. The SE2 archive ships
`LICENSES/DXC-README.txt`, which names this file as the corresponding
source.
