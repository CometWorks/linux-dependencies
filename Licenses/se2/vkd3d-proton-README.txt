vkd3d-proton build provenance
=============================

The shared libraries shipped alongside this notice as:

    libvkd3d-proton-d3d12.so
    libvkd3d-proton-d3d12core.so

are built from vkd3d-proton (https://github.com/HansKristian-Work/vkd3d-proton),
a Direct3D 12 implementation over Vulkan, at the upstream commit pinned in
Scripts/build_vkd3d_proton.sh of the CometWorks/linux-dependencies repository,
with the patch series published under Patches/vkd3d-proton/ of the same
repository applied.

License
-------
GNU Lesser General Public License version 2.1 — see VKD3D-LGPL-2.1.txt next
to this file.

LGPL notes
----------
The complete corresponding source of the shipped binaries is the pinned
upstream commit plus the published patch series, both recorded in the
CometWorks/linux-dependencies repository:

    https://github.com/CometWorks/linux-dependencies

The libraries are ordinary shared objects; to exercise the LGPL right to
relink or replace them, rebuild with Scripts/build_vkd3d_proton.sh (or any
equivalent build of the same sources) and substitute the resulting files.
