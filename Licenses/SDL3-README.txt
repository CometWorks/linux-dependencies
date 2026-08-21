SDL3 (Simple DirectMedia Layer)
===============================

The following shared library shipped alongside this notice is SDL 3.4.12:

    libSDL3.so         (SONAME: libSDL3.so.0)

License
-------
zlib license. See SDL3-LICENSE.txt in this directory for the full text.

The library is unmodified upstream SDL3 — no patches are applied. The only
post-build change to the binary is a patchelf step setting DT_RUNPATH=$ORIGIN,
matching every other library in this archive.

Source code
-----------
The library is built from the upstream release tag:

    https://github.com/libsdl-org/SDL  @  release-3.4.12

The exact build configuration used to produce the shipped binary is in the
CometWorks/linux-dependencies repository at Scripts/build_sdl3.sh:

    https://github.com/CometWorks/linux-dependencies

The cmake options and the post-build patchelf step are reproduced verbatim
there.

Why it is here
--------------
DXVK Native's window-system integration compiles against SDL3 and dlopens
"libSDL3.so.0" at runtime; the shipped libdxvk_*.so therefore have no NEEDED
entry for it. Bundling the same SDL3 the DXVK binaries were compiled against
means the pair is always a matched set, rather than depending on whatever
SDL3 — if any — the host distribution ships.

Video and audio backends
------------------------
X11 and Wayland video support is compiled in (both are required at build time,
so a build cannot silently produce a headless SDL), along with Vulkan surface
support, KMSDRM, and the usual audio backends. Those system libraries are
dlopened at runtime rather than linked, so the shipped binary depends only on
glibc and uses whichever display server and audio stack the host provides.

Replacing it
------------
The library is loaded by file name from the bundle directory. To use your own
SDL3, replace the shipped libSDL3.so with your build, keeping the SONAME
libSDL3.so.0 — that is the name DXVK dlopens, and it is what makes the
preloaded file satisfy the request.

Copyright
---------
SDL is copyright (c) 1997-2026 Sam Lantinga and the SDL contributors.
See https://libsdl.org/ for details.
