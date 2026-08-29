# DXC patches

Applied by `Scripts/build_dxc.sh` to DirectX Shader Compiler `v1.9.2607` in
byte-wise filename order before configuration.

`0001-se2-windows-wchar-abi.patch` converts strings directly in DXC's existing
ABI boundary methods. Vortice.Dxc uses Windows 2-byte `WCHAR` strings while
native Linux DXC uses 4-byte `wchar_t`; the patch converts compiler arguments,
result names, include callbacks, and include contents. It also preserves the
SE2-specific `-WX` filtering and ACP source length correction.
