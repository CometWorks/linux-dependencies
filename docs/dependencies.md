# Dependencies

Every library in the release archives, where it comes from, and how it is
pinned. To change any of these, see [maintenance.md](maintenance.md).

## Summary

Every library is built (or staged) **once**. The DXVK files and `libSDL3.so`
are shared byte-identically between the two game archives.

| Dependency | Archives | Version / pin | Licence | Built by |
| --- | --- | --- | --- | --- |
| FFmpeg | SE1 | 8.1 (release tarball) | LGPL-2.1-or-later | `Scripts/build_ffmpeg.sh` |
| DXVK Native + `Patches/dxvk/` series | both | tag `v3.0.2` + patch-series hash | zlib | `Scripts/build_dxvk.sh` |
| SDL3 | both | tag `release-3.4.12` | zlib | `Scripts/build_sdl3.sh` |
| vkd3d-proton + `Patches/vkd3d-proton/` series | SE2 | commit `3dfc6f07…` + patch-series hash | LGPL-2.1 | `Scripts/build_vkd3d_proton.sh` |
| DirectX Shader Compiler + `Patches/dxc/` series | SE2 | tag `v1.9.2607` (commit `0d3ee6b5…`) + patch-series hash | NCSA/LLVM Release License | `Scripts/build_dxc.sh` |
| AMD FidelityFX SDK + `Patches/fidelityfx/` series | SE2 | tag `v2.3.0` (commit `60f4ea81…`), shader compiler tag `v1.1.4` + patch-series hash | MIT | `Scripts/build_fidelityfx.sh` |
| OpenAL Soft | SE1 | 1.25.2 (release tarball) | LGPL-2.0-or-later | `Scripts/build_openal.sh` |
| Steamworks.NET | Steam | commit `68e72a49caf03a07722d4d4b471bbc7c0785f80b` | MIT | `Scripts/build_steamworks_net.sh` |
| EOS SDK | SE1 | vendor blob (manual) | proprietary (Epic) | committed under `Vendor/` |
| Steamworks SDK | Steam | vendor blob (manual) | proprietary (Valve) | committed under `Vendor/` |
| FMOD Engine | SE2 | vendor blob (manual), 2.03.11 to match the game | proprietary (Firelight) | committed under `Vendor/` |

SDL3 has a double role: it supplies the headers DXVK compiles against *and*
ships as `libSDL3.so`, because DXVK's window-system integration dlopens it at
runtime. See [SDL3](#sdl3-3412).

The DXC and FidelityFX patches are maintained in this repository; every
shipped binary is built from upstream or vendor source rather than
first-party source.

---

## FFmpeg 8.1

**Produces:** `libavcodec.so`, `libavformat.so`, `libavutil.so`,
`libswresample.so`, `libswscale.so` — one real file each under the bare
name (the archives carry no symlinks and no version-suffixed filenames).
The SONAMEs inside the binaries stay as upstream produced them
(`libavcodec.so.62`, …), but the cross-FFmpeg `NEEDED` entries are rewritten
to the bare names at staging time so `DT_RUNPATH=$ORIGIN` resolves siblings
against the files actually shipped.

**Source:** `https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz`, downloaded and
cached under `build/`.

**Consumed by:** Pulsar's audio and video playback, through FFmpeg.AutoGen 8.1,
loading the libraries by their bare file names. The upstream SOVERSIONs are
still pinned: `build_ffmpeg.sh` has an `EXPECTED_SOVER` table that fails the
build if they shift, because a shift means an upstream ABI bump that the
consumers' FFmpeg.AutoGen version must match.

### Why the build is configured the way it is

The goal is a set of libraries that depend on nothing but glibc and zlib, so
they run on any reasonably modern distribution without dragging in the build
host's codec stack. Every optional backend is disabled:

| Flag group | Effect |
| --- | --- |
| `--disable-programs`, `--disable-doc`, `--disable-*pages` | No `ffmpeg`/`ffplay`/`ffprobe` binaries or documentation — we only want libraries |
| `--disable-network` | Drops the TLS/SCTP/OpenSSL/GnuTLS dependency chain |
| `--disable-avdevice` | Skips the ALSA / PulseAudio / X11-grab / SDL input backends, and with them the implicit libxcb, libjack and libpulse pulls |
| `--disable-avfilter` | We only decode; no filter graph needed |
| `--disable-vaapi`, `--disable-vdpau`, `--disable-vulkan`, `--disable-libdrm`, `--disable-xlib` | No hardware-acceleration or display-server dependencies |
| `--disable-bzlib`, `--disable-lzma`, `--disable-iconv` | Drops bzip2 / xz / libiconv |
| `--disable-sdl2`, `--disable-alsa` | SDL3 is handled separately; FFmpeg's SDL support is only for `ffplay` |
| `--enable-shared`, `--disable-static`, `--enable-pic` | `.so` output only — a static `.a` cannot be P/Invoked from .NET |
| `--extra-ldflags=-Wl,-Bsymbolic` | Prefer in-library symbol resolution, so an unrelated `.so` or an `LD_PRELOAD` on the host cannot intercept FFmpeg-internal calls |
| `--cpu=x86-64-v2` | See below |

**zlib is deliberately left enabled.** Several muxers and demuxers (MOV,
Matroska) need it for compressed metadata, and zlib is present on every modern
Linux target, so it is not a portability concern.

**`--cpu=x86-64-v2`** pins the baseline instruction set to match .NET 10's
documented x64 minimum (CX16, POPCNT, SSE3, SSSE3, SSE4.1, SSE4.2 — Sandy
Bridge / Bulldozer, 2011 and newer). FFmpeg keeps its runtime SIMD dispatch on
top of this, so AVX/AVX2/AVX-512 paths are still selected on capable CPUs. The
flag only constrains the non-dispatched scalar code, and it stops a build host
with `CFLAGS=-march=native` from accidentally specializing the shipped
libraries to that machine.

**`--enable-gpl` and `--enable-nonfree` are NOT used**, so no GPL- or
nonfree-licensed FFmpeg components are linked in and the binaries are
distributable under the LGPL alone. The LGPL relinking notice shipped in the
archive (`LICENSES/FFmpeg-README.txt`) points back at `build_ffmpeg.sh` as the
authoritative build configuration, which is a licence obligation — keep that
pointer accurate.

### Post-build verification

1. **SOVERSION check** against the `EXPECTED_SOVER` table.
2. **`patchelf --set-rpath '$ORIGIN'`** on each library. This is done as a
   post-build rewrite rather than via `--extra-ldsoflags` because passing the
   literal `$ORIGIN` token through bash → FFmpeg's `configure` (sh) →
   `config.mak` → make → the recipe shell needs three layers of `$`-escaping
   that must survive both sh's `$$` → PID substitution and make's `$$` → `$`
   rule. At least one of those layers has been observed to break on FFmpeg 8.1,
   putting a literal PID into `DT_RUNPATH`. `patchelf` edits the `.dynamic`
   section after linking and is immune to all of it.
3. **`ldd` allow-list** — anything outside glibc, libz and the FFmpeg
   libraries themselves fails the build, which catches a disable flag that
   stopped working after an upstream change.
4. **`readelf` re-check** that `DT_RUNPATH` really is `$ORIGIN`, so a broken or
   missing `patchelf` step fails loudly instead of shipping libraries that
   silently need `LD_LIBRARY_PATH`.

---

## DXVK Native 3.0.2 (patched)

**Produces:** `libdxvk_d3d11.so` and `libdxvk_dxgi.so` (bare names, no
SONAME symlinks; `libdxvk_d3d11`'s `NEEDED` reference to the dxgi library is
rewritten from the SONAME to the bare name), built once with the
[Patches/dxvk/](../Patches/dxvk/) series applied and shipped identically in
both archives.

**Source:** `https://github.com/doitsujin/dxvk.git` at tag `v3.0.2`, shallow
clone with submodules, cached under `build/dxvk/`.

**Consumed by:** Pulsar and the Space Engineers 2 Linux port. Magnetar is
headless and does not need a D3D11 implementation. (The SE1 archive is
shared, so Magnetar simply ignores these files — see
[consuming.md](consuming.md).)

**How it is built:** by shelling out to upstream's own `package-native.sh`
helper with `--64-only --no-package`, rather than re-implementing the meson
invocation here. That script is short and stable across recent DXVK releases,
so upstream build tweaks are picked up for free. `--64-only` skips the 32-bit
build (Space Engineers is x86_64-only) and `--no-package` skips upstream's
tarball step, since only the installed `.so` files are wanted.

The output `.so` files are located with `find` rather than a hard-coded path,
so an upstream rearrangement (`usr/lib64/`, a multiarch subdirectory) does not
silently break staging. They then get the same `DT_RUNPATH=$ORIGIN` treatment
as the FFmpeg libraries.

### The patch series

The series under [Patches/dxvk/](../Patches/dxvk/) is applied onto the
pristine tag before every build. The patches are source-level fixes for DXVK
bugs the Space Engineers clients hit; fixing them here replaces what would
otherwise be a much larger set of managed (Harmony) runtime patches in the
Linux compatibility layers. The rationale for each patch is documented in
`Patches/dxvk/README.md` alongside its provenance. The most important one
makes `WCHAR` 16-bit (the Windows ABI) so `IDXGIAdapter::GetDesc*` cannot
overrun the caller's Windows-layout buffers.

Mechanics worth knowing:

* **Pristine base every run.** The cached clone is reset
  (`git checkout -- .` + `git clean -fdx`, including submodules) before the
  series is applied, so patches never stack across runs. This forfeits ninja
  incrementality — the price of a guaranteed clean base.
* **The series is part of the cache key.** `build/dxvk.stamp` records
  `<version> patches=<sha256 of the series>`, so adding, editing or removing
  a patch triggers a rebuild. An empty series is valid and builds pristine
  upstream.
* **A patch that fails to apply fails the build**, naming the patch — the
  signal that a `DXVK_VERSION` bump needs the series rebased.

---

## SDL3 3.4.12

DXVK's meson build refuses to configure without SDL3, SDL2 or GLFW, because
its window-system integration needs one of them. Pulsar sets
`DXVK_WSI_DRIVER=SDL3`, so it is specifically the SDL3 backend we need.

At build time SDL3 is a *headers-only* dependency. DXVK takes it as
`lib_sdl3.partial_dependency(compile_args: true, includes: true)`, so the
produced `libdxvk_*.so` have no `NEEDED` entry for SDL3. At runtime they
`dlopen("libSDL3.so.0")` instead — and that call has to find something.

Leaving that to the host was the previous arrangement and it is not
dependable: SDL3 is new enough that plenty of otherwise current distributions
ship no `libSDL3` at all, and the ones that do ship whatever version they
froze. Ubuntu 24.04 — the pinned CI runner — has no `libsdl3-dev` package
either. So `Scripts/build_sdl3.sh` builds a pinned SDL3 (**3.4.12**) into
`build/sdl3-prefix/`, `build_dxvk.sh` puts that on `PKG_CONFIG_PATH`, and the
same build is staged into **both** game archives as `libSDL3.so`. DXVK and the
SDL3 it was compiled against are then always a matched set.

**Produces:** `libSDL3.so` — the real file under the bare name, with
`DT_RUNPATH=$ORIGIN`, in the SE1 and SE2 archives (identical bytes). The
binary is unmodified upstream SDL3; no patch series applies to it.

**The SONAME matters here.** The shipped file is `libSDL3.so`, but DXVK
dlopens `libSDL3.so.0` — the SONAME inside the binary. Those only meet
because the consumer preloads the file first, after which the dlopen resolves
against the already-loaded object by SONAME. It is exactly the arrangement the
bundled OpenAL relies on, and `build_sdl3.sh` asserts the SONAME so an
upstream major bump cannot leave the bundled copy silently unused.

**Video drivers are required, not autodetected.** Because the library now
ships, it has to be able to open a window. SDL's CMake enables X11 and Wayland
by default but turns each off *silently* when its development headers are
missing — the same trap as OpenAL's audio backends, and the reason the old
`SDL_UNIX_CONSOLE_BUILD=ON` shortcut (which suppressed SDL's own "no X11 or
Wayland" error) is gone. SDL has no `REQUIRE_*` equivalent, so `build_sdl3.sh`
greps the generated `SDL_build_config.h` for `SDL_VIDEO_DRIVER_X11`,
`SDL_VIDEO_DRIVER_WAYLAND` and `SDL_VIDEO_VULKAN` and fails the build if any is
absent. The X11 and Wayland dev packages are correspondingly part of the
toolchain now; see [building.md](building.md).

Those display libraries are *dlopened* by SDL at runtime rather than linked
(`SDL_X11_SHARED` / `SDL_WAYLAND_SHARED`, both on), so the shipped
`libSDL3.so` still has no `NEEDED` entry beyond glibc and picks up whichever
display server and audio stack the host provides. `build_sdl3.sh` verifies
that with the same `ldd` allow-list the FFmpeg and OpenAL builds use.

## vkd3d-proton (patched, SE2 archive only)

**Produces:** `libvkd3d-proton-d3d12.so` and `libvkd3d-proton-d3d12core.so`,
built with the [Patches/vkd3d-proton/](../Patches/vkd3d-proton/) series
applied and staged straight into `build/Libraries-SE2/`.

**Source:** `https://github.com/HansKristian-Work/vkd3d-proton.git` at commit
`3dfc6f07d0953b1e8b41705275c2c59cc7374fc5`, fetched by SHA (depth 1) with
submodules, cached under `build/vkd3d-proton/`. The pin is a commit rather
than a tag because the patch series was developed and tested against exactly
this upstream state.

**Consumed by:** the Space Engineers 2 client, whose renderer is Direct3D 12
(VRage3 Render12). Space Engineers 1 is Direct3D 11 and never shipped a
D3D12 layer, so vkd3d-proton stays out of the SE1 archive — the SE1 library
set is unchanged from before the SE2 split.

**How it is built:** a plain native meson build (`--buildtype release`),
installed into `build/vkd3d-proton-out/` and staged from there. vkd3d-proton
generates its COM headers with `widl` (the Wine IDL compiler); the build
script accepts `widl`, `widl-stable`, or Ubuntu's
`x86_64-w64-mingw32-widl` from the `mingw-w64-tools` package, shimming the
latter onto `PATH` under the name meson expects.

The patch series, cache stamp, pristine-reset and failure behaviour follow
the same rules as DXVK above; the patches themselves (a DXGI adapter-parent
fix required for `CreateSwapChainForHwnd`, and an env-gated llvmpipe FP64
override used only by the CPU-rendering test harness) are documented in
`Patches/vkd3d-proton/README.md`.

Being LGPL-2.1, the SE2 archive carries `LICENSES/VKD3D-LGPL-2.1.txt` plus
`LICENSES/vkd3d-proton-README.txt` with build provenance and relinking notes
— the same obligation pattern as FFmpeg.

---

## DirectX Shader Compiler v1.9.2607 (SE2 archive only)

**Produces:** one file, staged straight into `build/Libraries-SE2/`:

| File | What it is |
| --- | --- |
| `libdxcompiler.so` | DXC built from source with the [SE2 ABI patch](../Patches/dxc/) |

**Source:** `https://github.com/microsoft/DirectXShaderCompiler.git` at tag
`v1.9.2607`, commit `0d3ee6b551b8fa768fbf825300ebab81047ef6a8`, cached under
`build/dxc/`. The tag ref is fetched rather than the bare SHA, because the
build's `LLVM_APPEND_VC_REV` runs `git describe` to fold the tag into
`PACKAGE_VERSION`; the script then asserts that the tag really resolves to
the pinned SHA, so a moved tag fails the build instead of shipping quietly.

**Consumed by:** the Space Engineers 2 client. SE2 compiles all of its
shaders at runtime through `Vortice.Dxc`, which P/Invokes `DxcCreateInstance`
from `dxcompiler.dll`; the Linux port redirects that to `libdxcompiler.so`.
Space Engineers 1 uses D3DCompiler, not DXC, so the file does not go into the
SE1 archive.

### Why this pin

`v1.9.2607` (2026-07-29) is the newest *stable* release. The whole `v1.10.x`
line is the Shader Model 6.10 preview branch and every release on it is
flagged as a prerelease upstream; `v1.10.2605.24` was observed aborting
inside LLVM (`User::allocHungoffUses`) while compiling SE2's Render12
shaders. Do not bump onto it.

Moving up from the previously shipped `v1.9.2602.24` prebuilt is safe for
SE2: the only breaking HLSL change in `v1.9.2607` is that the `volatile`
keyword is no longer accepted, and none of SE2's 660 shader source files use
it.

### Why the ABI patch exists

DXC's Linux `WCHAR` is the platform `wchar_t`, which is 4 bytes.
`Vortice.Dxc` marshals every string as the Windows 2-byte wire type. The two
ABIs disagree at every string argument and every string-returning interface,
so the patch converts compiler arguments, result names and include callbacks
at the existing DXC ABI boundaries.

Building DXC with `-fshort-wchar` instead — making the whole library speak
2-byte `WCHAR` so no shim is needed — does not work. `libdxcompiler.so`
imports eight wide-char functions from glibc (`wcslen`, `wcscmp`, `wcsncmp`,
`wcsncpy`, `wmemcmp`, `wmemcpy`, `mbstowcs`, `wcstombs`), and a 2-byte
`wchar_t` build would silently mismatch every one of them.

The patch also removes `-WX` and corrects ACP source lengths, preserving the
behavior previously supplied by the separate bridge library.

### Why `libdxil.so` is not shipped

The Microsoft prebuilt release carries a third file, `libdxil.so`, the
signing validator. It is deliberately absent here, on three grounds:

* **It is not used.** Compiling a shader with `libdxil.so` beside
  `libdxcompiler.so` and again with it absent produces byte-identical
  containers carrying the same non-zero DXIL hash, and `LD_DEBUG=libs` shows
  it is never `dlopen`ed either way.
* **It is not needed.** Microsoft open-sourced the DXIL validator hash, so
  `ComputeHashRetail` is compiled directly into `libdxcompiler.so` —
  `readelf -sW` shows it as a locally defined function there.
* **It is not buildable.** `libdxil.so` exists only as a prebuilt release
  artefact. Dropping it is what makes a payload that is entirely built from
  source possible, and with it the Microsoft binary distribution terms that
  used to apply.

### How it is built

A cmake + ninja release build driven by DXC's own
`cmake/caches/PredefinedParams.cmake`, with assertions and both test suites
turned off, building only the `dxcompiler` target — not the `dxc` driver
executable. Flag order in the `cmake` invocation is load-bearing: the cache
file's `set()`s are non-`FORCE`, so a `-D` overrides them only when it
appears *before* the `-C`.

The SPIR-V backend is dead weight for SE2, which never passes `-spirv`, but
it cannot be switched off: DXC's root `CMakeLists.txt` does an unconditional
`if(NOT WIN32) set(ENABLE_SPIRV_CODEGEN ON) endif()` that shadows both the
cache and the command line. `external/SPIRV-Headers` and
`external/SPIRV-Tools` therefore have to be initialised along with
`external/DirectX-Headers` (which DXC requires on any non-Windows target).
Only `external/googletest` stays uncloned, because the test suites are off.

SPIRV-Tools is statically linked into the shipped `libdxcompiler.so`, so the
SE2 archive also carries `LICENSES/DXC-BUNDLED-LICENSES.txt` with the
Apache-2.0, Khronos and MIT texts for SPIRV-Tools, SPIRV-Headers and
DirectX-Headers, next to `LICENSES/DXC-LICENSE.txt` and
`LICENSES/DXC-README.txt`.

The build is about 19 minutes on a GitHub-hosted 4-vCPU runner, and by far
the longest step in the pipeline — more than everything else combined. The cmake build tree (~270 MB) is deleted once the
output is staged; set `DXC_KEEP_BUILD_TREE=1` to keep it when iterating. The
clone itself (~250 MB) stays to avoid another fetch on the next build.

### Post-build verification

The script asserts that the generated `include/llvm/Config/config.h` reads
`PACKAGE_VERSION "3.7-v1.9.2607-dirty"` before deleting the build tree; the
suffix records the applied patch series. The
corresponding runtime string is *not* checkable with `strings` on the
finished `.so`: those literals end up in an unterminated 16-byte merged
constant pool where the tag reads back truncated as `3.7-v1.9.26`.

---

## AMD FidelityFX FSR 3.1.5 (SE2 archive only)

**Produces:** `libamd_fidelityfx_loader_dx12.so`, staged straight into
`build/Libraries-SE2/`, with the
[Patches/fidelityfx/](../Patches/fidelityfx/) series applied.

**Source:** `https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK.git`
at tag `v2.3.0` (commit `60f4ea81909200d8542eca14dccb2628b763a9a3`), plus a
second checkout of the same repository at tag `v1.1.4` (commit
`c6efa6bf7f20…`) for the shader compiler. Both are sparse clones — the full
repository is several GB of samples and media, of which this build needs
about 190 MB — cached under `build/fidelityfx/` and `build/ffx-sc-src/`.

**Consumed by:** the Space Engineers 2 client. When the graphics Quality
setting selects FSR upscaling, `VRage.Render12`'s `FSR4_1Context` P/Invokes
five entry points — `ffxCreateContext`, `ffxDestroyContext`, `ffxConfigure`,
`ffxQuery` and `ffxDispatch` — from `amd_fidelityfx_loader_dx12.dll`. That is
AMD's flat `ffx_api` ABI: plain C functions taking `ffxApiHeader` struct
chains, with the renderer's own `ID3D12Device*` and `ID3D12Resource*` pointers
passed straight through. No Windows ABI crosses the boundary, so a native
SysV `.so` exporting those five symbols is a drop-in replacement.

### What is in the library

The `ffx_api` dispatcher, the DirectX 12 backend and the FSR 3.1.5 upscaler
provider are linked into a single object. AMD's Windows build discovers
providers by loading separate upscaler DLLs; linking the one provider that
has source sidesteps that machinery, so nothing is `dlopen`ed at run time
except the D3D12 library (see below).

FSR 3.1.5 is the only upscaler included. FSR 4.x ships as a prebuilt, signed
Windows DLL with no source, and the driver-side ("external") provider lives
behind `FFX_BACKEND_DX12` in AMD's closed `amdinternal` tree — neither can be
part of a from-source build. The plugin side of the port forces the game's
`ForceUseFSR_3_1` setting on to match, which makes the game's own
"FSR upscaler provider selected: …" log line say `3.1.5`.

`GetProvider()`/`GetProviderVersions()` are declared in the SDK but never
defined there: each of AMD's shipping loader DLLs supplies its own definition
naming the providers it was built with. The patch series adds that file.

### How it is built

The DX12 backend is compiled against **vkd3d-proton's installed headers**
(`build/vkd3d-proton-out/include/vkd3d-proton/`), so the `ID3D12Device` and
`ID3D12Resource` vtables it compiles against are by construction the ones the
game passes in. `build_fidelityfx.sh` therefore runs after
`build_vkd3d_proton.sh` in the pipeline, and invokes it itself if those
headers are missing. A handful of generated forwarding headers map the SDK's
`<d3d12.h>`, `<dxgi.h>` and friends onto vkd3d-proton's `vkd3d_`-prefixed
names.

Everything is compiled with `-fvisibility=hidden`; only the five `ffx_api`
entry points carry default visibility, and the build asserts that all five are
exported before staging. The library is linked with `-Wl,--no-undefined`, so a
missing symbol is a link error here rather than a `dlopen` failure inside the
game, and gets `DT_RUNPATH=$ORIGIN` like the other payloads.

### Shaders

The ten FSR 3.1 compute passes are compiled to DXIL during the build, in four
variants each (wave32/wave64 × fp32/fp16), each expanding six boolean shader
options into 64 permutations. The compiler is AMD's own FidelityFX_SC, which
generates the permutation headers the upscaler's shader blob tables are built
from. The 2.x releases ship it only as a prebuilt Windows `.exe`, so the
build takes it from the last release that published its source (`v1.1.4`) and
ports it — that is what the second checkout is for. The permutation
expansion, define sets and shader models are a transcription of the SDK's own
`BuildFSR3UpscalerShaders.bat`.

FidelityFX_SC drives DXC in-process through `DxcCreateInstance`, and it must
be a **stock** DXC: the shipped `libdxcompiler.so` carries the SE2 2-byte
`WCHAR` ABI patch and is deliberately incompatible with a normal
4-byte-`wchar_t` caller. The build therefore keeps a second, unpatched DXC
build tree (`build/dxc-host/`) at the same pin as `Scripts/build_dxc.sh`,
read out of that script rather than duplicated. It is cached under its own
stamp (`build/dxc-host.stamp`), is not shipped, and is the only expensive part
of this step — everything after it takes seconds.

The generated DXIL is unsigned, for the same reason
[`libdxil.so` is not shipped](#why-libdxilso-is-not-shipped): vkd3d-proton
does not validate DXIL signatures.

### The Linux port

The patch series is documented file by file in
[`Patches/fidelityfx/README.md`](../Patches/fidelityfx/README.md). The
substantive items are MSVC-only CRT calls (`sprintf_s`, `wcscpy_s` and
friends), the AGS and PIX tracing paths (both `LoadLibraryW` Windows-only
DLLs), Microsoft's MSVC-only `d3dx12.h` helpers, Win32 diagnostics, and two
consequences of Linux `wchar_t` being 4 bytes rather than 2: every `SetName`
call has to narrow to the D3D12 ABI's 2-byte `WCHAR`, and the private effect
contexts outgrow the SDK's own size reservation.

`D3D12SerializeRootSignature` was resolved through
`GetModuleHandleW(L"D3D12.dll")`; it is now `dlopen`/`dlsym` against
`libvkd3d-proton-d3d12.so`, which exports it. `RTLD_NOLOAD` is tried first, so
the reference is to the caller's already-loaded instance rather than a second
private copy.

### Post-build verification

The script asserts that `ffxCreateContext`, `ffxDestroyContext`,
`ffxConfigure`, `ffxQuery` and `ffxDispatch` are all exported by the built
library before staging it. A missing entry point there would otherwise
surface as a `DllNotFoundException` on the game's render thread.

Every source file compiled into the library is named in the exception list of
the SDK's own `docs/license.md` and is therefore MIT-licensed, not covered by
the SDK's default binary-redistribution terms. The SE2 archive carries
`LICENSES/FidelityFX-LICENSE.txt` and `LICENSES/FidelityFX-README.txt`.

---

## OpenAL Soft 1.25.2

**Produces:** `libopenal.so` — the real file under the bare name. The SONAME
inside the binary remains `libopenal.so.1` (asserted at build time) but no
file is named after it; consumers load the library by file name.

**Source:** `https://openal-soft.org/openal-releases/openal-soft-1.25.2.tar.bz2`,
downloaded and cached under `build/`. A tarball URL is mutable, so unlike the
git-tag clones elsewhere the pin here is a SHA-256 checksum, verified on every
run.

**Consumed by:** Pulsar only. Space Engineers' Linux audio goes through
Silk.NET.OpenAL (used by se-linux-compat), loading the bundled `libopenal.so`
by file name. Magnetar is headless and does not stage it.

**Why it lives here.** It used to be handled three different ways depending on
the bundle: compiled from source inside Pulsar's Flatpak manifest, and left to
LinuxCompat's `Assets/` or the host for the developer 7z. It was the last
native dependency outside the shared pipeline. Building it here gives both
bundles the same pinned binary and removes a from-source compile from every
Flatpak build.

### Backends are pinned deliberately

OpenAL compiles a backend in only when its development headers are present at
build time, then dlopens the actual library at runtime. Left to autodetection,
a build host without `libpulse-dev` would silently produce a `libopenal` with
no PulseAudio backend — a library that loads fine and then plays no sound.

The build therefore passes `ALSOFT_REQUIRE_PIPEWIRE`, `ALSOFT_REQUIRE_PULSEAUDIO`
and `ALSOFT_REQUIRE_ALSA`, turning a missing header into a configure-time
failure. OSS is enabled too (it needs no library). JACK, PortAudio, SndIO and
the SDL backends are explicitly disabled — each would add a dev package to the
runner, and upstream keeps the SDL backend off by default because it adds a
runtime dependency.

`CMAKE_DISABLE_FIND_PACKAGE_SDL3` stops the unconditional `find_package(SDL3)`
at the top of upstream's `CMakeLists.txt` from tripping over whatever SDL3 the
build host happens to have — a broken or partial system install otherwise
fails the configure even though the backend is off.

Because the backends are dlopened rather than linked, the shipped library's
only `NEEDED` entries are glibc, `libstdc++` and `libgcc_s`. The `ldd`
allow-list enforces that: a `NEEDED` entry for `libpulse` would mean the bundle
hard-requires that specific audio stack.

### Post-build verification

The **SONAME is asserted** to be `libopenal.so.1`. The shipped file is the
bare `libopenal.so` either way, but a SONAME bump signals an upstream
major-version (ABI) change that the consumers should review rather than pick
up silently. `DT_RUNPATH=$ORIGIN` is patched on and re-checked, as for
FFmpeg and DXVK.

---

## Steamworks.NET

**Produces:** `Steamworks.NET.dll` (managed, `net8.0`), staged into
`build/Libraries-Steam/` and shipped in the Steam archive next to
`libsteam_api.so`, the native runtime it P/Invokes.

**Source:** `https://github.com/rlabrecque/Steamworks.NET.git` at commit
`68e72a49caf03a07722d4d4b471bbc7c0785f80b`, built from
`Standalone3.0/Steamworks.NET.csproj` with `dotnet build -c Release`.

**Consumed by:** both Pulsar and Magnetar, as an assembly reference in their
`Shared/Shared.csproj`.

**Why a commit and not a tag:** rlabrecque's tags track Steamworks SDK
versions, but the `.dll` both consumers historically shipped was built straight
from a HEAD commit. That commit SHA is embedded in the old binary's
`AssemblyInformationalVersion`, and it is the value pinned here, so the
rebuilt assembly matches what the consumers were already using.

The pinned commit lives on a pull-request ref (PR #738, "Upgrade Steamworks SDK
to v1.64"), which a plain `git clone` does not fetch. The script tries a direct
checkout first and, on failure, fetches `refs/pull/*/head` and retries — so the
pin keeps working whether or not that PR is ever merged.

**Caching:** `build/steamworks-net.stamp` records the built commit SHA.

---

## Vendor blobs

Two proprietary runtimes are committed under `Vendor/` rather than built:

* **`libEOSSDK-Linux-Shipping.so`** — the Epic Online Services SDK runtime.
  Needed by both consumers: Pulsar for the client's EOS integration, and
  Magnetar because `MySteamService.UpdateNetworkThread` drives
  `MyEOSNetworking` even under Steam-only networking.
* **`libsteam_api.so`** — the Steamworks SDK runtime, shipped in the Steam
  archive next to `Steamworks.NET.dll`.

Neither has a public source repository or a publicly fetchable binary; both
downloads are gated behind logged-in partner portals. Updating them is a manual
maintainer task documented in [maintenance.md](maintenance.md) and in
[Vendor/README.md](../Vendor/README.md).

A third proprietary runtime ships in the SE2 archive only:

* **`libfmod.so`, `libfmodstudio.so`** — the FMOD Engine runtime
  (Core + Studio), version **2.03.11** to match the FMOD the game ships.
  Committed under `Vendor/` with the upstream SONAME file names
  (`libfmod.so.14`) for provenance, staged into the archive under the bare
  names, binaries unmodified. The FMOD API is version-locked: SE2's managed
  wrapper is generated for the game's FMOD version, so these must track it
  at least to the minor release. SE1 does not use FMOD.

Provenance and update rules: [Vendor/README.md](../Vendor/README.md).

The SE2 native wrappers (`libVRage.*.Native.so`) are **not** shipped here —
like the SE1 PE-loader wrappers, they are built and released by
[CometWorks/linux-native-wrappers](https://github.com/CometWorks/linux-native-wrappers)
and consumers fetch them separately.

---

## Licences

`Licenses/*.txt` are committed licence texts and attribution notices, copied
into the archive as `LICENSES/`. They travel with the binaries so that any
bundle built from this archive carries the attribution its licences require —
in particular the LGPL notice for FFmpeg, which must point at the build
configuration used to produce the shipped libraries.

Every SE2 payload is now either built from source or a clearly identified
vendor blob (FMOD). Nothing in the archive is redistributed under a binary
EULA that this repository cannot also supply the sources for, which is the
practical consequence of building DXC rather than unpacking Microsoft's
release download.
