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
    VKD3D-LGPL-2.1.txt            LGPL-2.1 text covering
                                  libvkd3d-proton-d3d12*.so
    vkd3d-proton-README.txt       Build provenance + LGPL relinking notes
                                  (patch series under Patches/vkd3d-proton/)
    FMOD-EULA.txt                 FMOD End User License Agreement covering
                                  libfmod.so.14 and libfmodstudio.so.14
                                  (proprietary, Firelight Technologies)
    FMOD-NOTICE.txt               FMOD attribution notice

This is the SE2 companion archive (linux-dependencies-se2.tar.gz). The
Space Engineers 1 libraries and their licences ship separately in
linux-dependencies.tar.gz; the patched DXVK binaries are identical in both.
