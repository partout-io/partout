# WinRT VPN channel runtime

## VPN channel runtime

On Windows, C++ consumers include `partout.h` for the C ABI and then
`runtime.h` for `PartoutVpnChannelRuntime`. Construct it with a retained
`VpnChannel`, profile JSON, logger settings, and nonblocking daemon options
(`is_daemon = false`). The runtime copies the profile and cache path.
Serialize calls and forward the five `IVpnPlugIn` callbacks unchanged.
The runtime creates an internal controller for the daemon bindings and stops
the daemon before releasing its channel and transport, including on destruction.

CMake links the MSVC-built bridge into `partout.dll`, which exports these C++
methods. Shared-library consumers link only Partout's import library and use a
compatible MSVC runtime. CMake always builds Partout as a shared library.
Both headers are installed on Windows.
Of the installed headers, only `runtime.h` depends on the Windows SDK's C++/WinRT headers.

Transport association is pending the Windows socket backend rewrite. Tunnel
addresses remain placeholders, and packet encapsulation and decapsulation are stubs.

## Build the runtime bridge

Windows Zig builds use a dummy tunnel controller by default and do not link WinRT.
Pass `-Dwinrt=true` (for example, `zig build test -Dwinrt=true`) to build and link the WinRT bridge.
This requires CMake 4.0+, Visual Studio 2022 with the target C++ tools, and the
Windows SDK. Native Zig builds default to the MSVC ABI.

To build the bridge separately, use a Visual Studio developer shell:

```powershell
cmake -S . -B .cmake-winrt -G Ninja -DCMAKE_BUILD_TYPE=Release -DPP_BUILD_WINRT=ON -DPP_BUILD_LIBRARY=OFF
cmake --build .cmake-winrt
```

With `PP_BUILD_LIBRARY=ON`, CMake passes the bridge archive to Zig through
`-Dwinrt-lib`. This option also enables WinRT and lets direct Zig builds use a prebuilt archive
with a matching Windows MSVC target. Native consumers of the standalone archive must
also link `windowsapp` and `runtimeobject` and use the DLL MSVC runtime.

The previous socket implementation and its loopback tests have been removed.
Windows socket creation returns `LinkNotActive` until the replacement is ready.
