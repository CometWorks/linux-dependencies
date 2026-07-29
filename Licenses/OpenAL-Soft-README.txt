OpenAL Soft
===========

The following shared library shipped alongside this notice is OpenAL Soft
1.25.2:

    libopenal.so       (-> libopenal.so.1)

License
-------
GNU Library General Public License version 2 (LGPL-2.0-or-later).
See OpenAL-Soft-LGPL-2.0.txt in this directory for the full license text.

Portions are additionally covered by a BSD 3-Clause license, and a modified
copy of PFFFT is included under its own permissive license. Both texts are in
OpenAL-Soft-NOTICES.txt in this directory.

Source code
-----------
The library is built from the upstream OpenAL Soft 1.25.2 release tarball:

    https://openal-soft.org/openal-releases/openal-soft-1.25.2.tar.bz2

The exact build configuration used to produce the shipped binary is in the
CometWorks/linux-dependencies repository at Scripts/build_openal.sh:

    https://github.com/CometWorks/linux-dependencies

The cmake options and the post-build patchelf step are reproduced verbatim
there.

Per the LGPL, users have the right to relink the application against a
modified OpenAL of their choosing. The library is loaded via dlopen at
runtime, so the user can simply replace the shipped .so with their own build
(keeping the same SONAME, libopenal.so.1) and the application will pick it up
automatically.

Audio backends
--------------
PipeWire, PulseAudio, ALSA and OSS support is compiled in. Those libraries are
dlopened at runtime rather than linked, so the shipped binary depends only on
glibc and the C++ runtime, and uses whichever audio stack the host provides.
The JACK, PortAudio, SndIO and SDL backends are disabled.

Copyright
---------
OpenAL Soft is copyright (c) the OpenAL Soft contributors.
See https://openal-soft.org/ for details.
