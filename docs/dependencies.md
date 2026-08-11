# Dependencies

Every library in the release archives, where it comes from, and how it is
pinned. To change any of these, see [maintenance.md](maintenance.md).

## Summary

Every library is built (or staged) **once**; DXVK and vkd3d-proton are
patched and the identical binaries ship in both archives.

| Dependency | Archives | Version / pin | Licence | Built by |
| --- | --- | --- | --- | --- |
| FFmpeg | SE1 | 8.1 (release tarball) | LGPL-2.1-or-later | `Scripts/build_ffmpeg.sh` |
| DXVK Native + `Patches/dxvk/` series | both | tag `v2.7.1` + patch-series hash | zlib | `Scripts/build_dxvk.sh` |
| vkd3d-proton + `Patches/vkd3d-proton/` series | both | commit `3dfc6f07…` + patch-series hash | LGPL-2.1 | `Scripts/build_vkd3d_proton.sh` |
| OpenAL Soft | SE1 | 1.25.2 (release tarball) | LGPL-2.0-or-later | `Scripts/build_openal.sh` |
| Steamworks.NET | SE1 | commit `68e72a49caf03a07722d4d4b471bbc7c0785f80b` | MIT | `Scripts/build_steamworks_net.sh` |
| EOS SDK | SE1 | vendor blob (manual) | proprietary (Epic) | committed under `Vendor/` |
| Steamworks SDK | SE1 | vendor blob (manual) | proprietary (Valve) | committed under `Vendor/` |
| FMOD Engine | SE2 | vendor blob (manual), 2.03.11 to match the game | proprietary (Firelight) | committed under `Vendor/` |

`Scripts/build_sdl3.sh` builds SDL3 3.4.12 as well, but nothing from it is
shipped — it exists only so DXVK has headers to compile against. See
[SDL3 is a build-time dependency](#sdl3-is-a-build-time-dependency).

---

## FFmpeg 8.1

**Produces:** `libavcodec.so.62`, `libavformat.so.62`, `libavutil.so.60`,
`libswresample.so.6`, `libswscale.so.9`, each with an unversioned `.so` alias
and a fully-versioned real file.

**Source:** `https://ffmpeg.org/releases/ffmpeg-8.1.tar.xz`, downloaded and
cached under `build/`.

**Consumed by:** Pulsar's audio and video playback, through FFmpeg.AutoGen 8.1.
The SOVERSIONs are not incidental — `ClientPlugin/Audio/MySdlAudioInterop.cs`
in Pulsar contains a `LibraryVersionMap` that names them explicitly, so a
SOVERSION bump on either side without the other produces a
`DllNotFoundException` at runtime. `build_ffmpeg.sh` has an `EXPECTED_SOVER`
table that fails the build if the versions shift.

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

## DXVK Native 2.7.1 (patched)

**Produces:** `libdxvk_d3d11.so` and `libdxvk_dxgi.so`, each with a `.so.0`
SONAME symlink, built once with the [Patches/dxvk/](../Patches/dxvk/) series
applied and shipped identically in both archives.

**Source:** `https://github.com/doitsujin/dxvk.git` at tag `v2.7.1`, shallow
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

### SDL3 is a build-time dependency

DXVK's meson build refuses to configure without SDL3, SDL2 or GLFW, because
its window-system integration needs one of them. Pulsar sets
`DXVK_WSI_DRIVER=SDL3` and preloads `libSDL3.so` from the user's system, so it
is specifically the SDL3 backend we need.

SDL3 is a *headers-only* dependency here. DXVK takes it as
`lib_sdl3.partial_dependency(compile_args: true, includes: true)` and dlopens
`libSDL3.so.0` at runtime, so the produced `libdxvk_*.so` have no `NEEDED`
entry for SDL3 and nothing SDL-related ships in the archive.

Ubuntu 24.04 — the pinned CI runner — has no `libsdl3-dev` package, and a
developer machine may have any SDL3 version or none. `Scripts/build_sdl3.sh`
therefore builds a pinned SDL3 (**3.4.12**) into `build/sdl3-prefix/` and
`build_dxvk.sh` puts that on `PKG_CONFIG_PATH`, so CI and local builds compile
against identical headers.

That SDL3 is configured with `SDL_UNIX_CONSOLE_BUILD=ON`, which skips SDL's
"could not find X11 or Wayland development libraries" hard error. The check
guards against accidentally building an SDL that cannot open a window — which
does not matter here, since nothing links or loads this SDL and the public
headers are the same either way. It saves installing the entire X11 and
Wayland dev stack on the runner to build a library that is then discarded.

Both choices were verified to be neutral: DXVK built against the pinned,
console-only 3.4.12 is byte-identical to DXVK built against a full system
SDL3 3.5.0.

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

## vkd3d-proton (patched)

**Produces:** `libvkd3d-proton-d3d12.so` and `libvkd3d-proton-d3d12core.so`,
built once with the [Patches/vkd3d-proton/](../Patches/vkd3d-proton/) series
applied and shipped identically in both archives.

**Source:** `https://github.com/HansKristian-Work/vkd3d-proton.git` at commit
`3dfc6f07d0953b1e8b41705275c2c59cc7374fc5`, fetched by SHA (depth 1) with
submodules, cached under `build/vkd3d-proton/`. The pin is a commit rather
than a tag because the patch series was developed and tested against exactly
this upstream state.

**Consumed by:** the Space Engineers 2 client, whose renderer is Direct3D 12
(VRage3 Render12). It ships in the SE1 archive as well under the
patched-libraries-appear-in-both policy; SE1 consumers simply ignore it.

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

Being LGPL-2.1, the archives carry `LICENSES/VKD3D-LGPL-2.1.txt` plus
`LICENSES/vkd3d-proton-README.txt` with build provenance and relinking notes
— the same obligation pattern as FFmpeg.

---

## OpenAL Soft 1.25.2

**Produces:** `libopenal.so.1`, with an unversioned `libopenal.so` alias.

**Source:** `https://openal-soft.org/openal-releases/openal-soft-1.25.2.tar.bz2`,
downloaded and cached under `build/`. A tarball URL is mutable, so unlike the
git-tag clones elsewhere the pin here is a SHA-256 checksum, verified on every
run.

**Consumed by:** Pulsar only. Space Engineers' Linux audio goes through
Silk.NET.OpenAL (used by se-linux-compat), which dlopens `libopenal.so.1` at
runtime. Magnetar is headless and does not stage it.

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

The **SONAME is asserted** to be `libopenal.so.1`. Silk.NET dlopens by SONAME,
so a bump would leave the bundled copy unused while the application silently
fell back to the host's — or found none at all. `DT_RUNPATH=$ORIGIN` is patched
on and re-checked, as for FFmpeg and DXVK.

---

## Steamworks.NET

**Produces:** `Steamworks.NET.dll` (managed, `net8.0`).

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
* **`libsteam_api.so`** — the Steamworks SDK runtime.

Neither has a public source repository or a publicly fetchable binary; both
downloads are gated behind logged-in partner portals. Updating them is a manual
maintainer task documented in [maintenance.md](maintenance.md) and in
[Vendor/README.md](../Vendor/README.md).

A third proprietary runtime ships in the SE2 archive only:

* **`libfmod.so.14`, `libfmodstudio.so.14`** — the FMOD Engine runtime
  (Core + Studio), version **2.03.11** to match the FMOD the game ships.
  The FMOD API is version-locked: SE2's managed wrapper is generated for the
  game's FMOD version, so these must track it at least to the minor release.
  SE1 does not use FMOD.

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
