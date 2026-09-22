# Windows WinRT backend

The native backend owns WinRT objects. Partout owns the portable ABI adapters;
the backend interfaces do not import Partout portable headers.

## Layout and dependencies

| Location | Responsibility |
| --- | --- |
| `include/partout_winrt.h` | Plugin-facing C++ runtime API; depends on `partout.h`. |
| `include/winrt/` | Backend-owned socket, tunnel controller and logging interfaces. |
| `src/runtime.cc` | Integrates VPN plugin callbacks with Partout; the only native source importing the Partout API. |
| `src/socket.cc` | Reserved for the native socket implementation. |
| `src/tun_ctrl.h`, `src/tun_ctrl.cc` | Private `PartoutTunnelController` and native controller callbacks. |
| `src/log.cc` | Optional process-wide logger, with a debugger-output fallback. |
| `../../src/c/portable/tun_winrt.c` | Converts the portable controller ABI into backend calls. |

`partout-winrt-backend` compiles with only the native include directory.
`partout-winrt` adds `runtime.cc` and packages all objects into one archive for
Zig. Partout depends on the backend; the backend does not depend on the portable ABI.

## VPN channel runtime

C++ plugins include `partout_winrt.h` and construct `PartoutVpnChannelRuntime`
with a retained `VpnChannel`, profile JSON, logger settings and nonblocking
daemon options (`is_daemon = false`). The runtime copies the profile and cache
path. Serialize calls and forward the five `IVpnPlugIn` callbacks unchanged.
The runtime stops Partout before releasing the controller and transport.

CMake builds Partout as a shared library and installs `partout.h` and
`partout_winrt.h`. Plugins link Partout's import library with a compatible MSVC
runtime. Backend headers are internal integration interfaces, not installed
plugin headers.

Socket I/O and transport association are pending. Channel addresses remain
placeholders; packet TUN I/O, encapsulation/decapsulation, controller notifications
and WindowsLooper timers remain unimplemented.

## Build

Requires CMake 4.0+, Visual Studio 2022 C++ tools and the Windows SDK. From the
Partout root in a developer shell matching the target architecture:

```powershell
cmake -S . -B .cmake-winrt -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_WINRT=ON -DPP_BUILD_LIBRARY=OFF
cmake --build .cmake-winrt --target partout-winrt
```

With `PP_BUILD_LIBRARY=ON`, CMake passes the archive to Zig through
`-Dwinrt-lib`. Direct Zig builds can use `-Dwinrt=true` to build the archive or
`-Dwinrt-lib=<path>` to reuse one matching the Windows MSVC target. Windows
builds without WinRT use `tun_windows_dummy.c`, an intentional fallback for
tests and builds that do not need native VPN support.
