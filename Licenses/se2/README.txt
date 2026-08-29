Third-party licences for the binaries shipped in ../
====================================================

The libraries in the parent directory are each governed by their own
licence. This directory collects the licence text and attribution required
when redistributing them as part of a Space Engineers 2 Linux bundle.

Files in this directory:

    DXVK-LICENSE.txt              zlib licence covering libdxvk_*.so* (built
                                  from upstream DXVK plus the patch series
                                  published under Patches/dxvk/ in the
                                  CometWorks/linux-dependencies repository)
    SDL3-LICENSE.txt              zlib licence covering libSDL3.so
                                  (unmodified upstream SDL3, dlopened by
                                  DXVK's window-system integration)
    SDL3-README.txt               Build provenance + replacement notes
    VKD3D-LGPL-2.1.txt            LGPL-2.1 text covering
                                  libvkd3d-proton-d3d12*.so
    vkd3d-proton-README.txt       Build provenance + LGPL relinking notes
                                  (patch series under Patches/vkd3d-proton/)
    DXC-LICENSE.txt               LLVM Release License (University of
                                  Illinois/NCSA), with MIT-licensed portions,
                                  covering libdxcompiler.so — the verbatim
                                  LICENSE.TXT of the pinned DXC source tree
    DXC-BUNDLED-LICENSES.txt      Apache-2.0, Khronos and MIT texts for
                                  SPIRV-Tools, SPIRV-Headers and
                                  DirectX-Headers, which are statically
                                  linked into libdxcompiler.so
    DXC-README.txt                Build provenance for the patched
                                  libdxcompiler.so; why libdxil.so is absent
    FidelityFX-LICENSE.txt        MIT licence covering
                                  libamd_fidelityfx_loader_dx12.so, built from
                                  the MIT-licensed portion of the AMD FSR SDK
                                  (patch series under Patches/fidelityfx/)
    FidelityFX-README.txt         Build provenance for the FSR 3.1.5 upscaler
                                  library and its shader compilation
    FMOD-EULA.txt                 FMOD End User License Agreement covering
                                  libfmod.so and libfmodstudio.so
                                  (proprietary, Firelight Technologies)
    FMOD-NOTICE.txt               FMOD attribution notice

This is the SE2 companion archive (se2-dependencies.tar.gz). The
Space Engineers 1 libraries and their licences ship separately in
se1-dependencies.tar.gz; the patched DXVK binaries and libSDL3.so are
identical in both.
