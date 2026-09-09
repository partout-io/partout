# WinRT sockets

## VPN channel runtime

On Windows, C++ consumers include `partout.h` for the C ABI and then
`partout_winrt.h` for `PartoutVpnChannelRuntime`. Construct it with a retained
`VpnChannel`, profile JSON, logger settings, and nonblocking daemon options
(`is_daemon = false`). The runtime copies the profile and cache path.
Serialize calls and forward the five `IVpnPlugIn` callbacks unchanged.
The runtime creates an internal controller for the daemon bindings and stops
the daemon before releasing its channel and transport, including on destruction.

CMake links the MSVC-built bridge into `partout.dll`, which exports these C++
methods. Shared-library consumers link only Partout's import library and use a
compatible MSVC runtime. CMake always builds Partout as a shared library.
Both headers are installed on Windows.
Only `partout_winrt.h` depends on the Windows SDK's C++/WinRT headers.

The runtime currently preserves the plugin's demonstration transport and
addresses. Packet encapsulation and decapsulation remain stubs.

## Socket bridge

`socket.cc` implements a C ABI for `WindowsSocketWrapper` in
`src/net/io_windows.zig`. It requires MSVC, C++20, the Windows SDK's C++/WinRT
headers. The bridge initializes WinRT per calling thread. Handles must be used serially.

Build with a Visual Studio developer shell:

```powershell
cmake -S . -B .cmake-winrt -G Ninja -DCMAKE_BUILD_TYPE=Release -DPP_BUILD_WINRT=ON -DPP_BUILD_LIBRARY=OFF -DPP_TEST_WINRT=ON
cmake --build .cmake-winrt
ctest --test-dir .cmake-winrt --output-on-failure
```

With `PP_BUILD_LIBRARY=ON`, CMake passes the bridge archive to Zig through
`-Dwinrt-lib`. For a direct Zig build, supply that option yourself with a
matching Windows MSVC target. Native consumers of the standalone archive must
also link `windowsapp` and `runtimeobject` and use the DLL MSVC runtime.

`init` starts connecting and returns immediately. `poll`, `read`, and `write`
return `WouldBlock` while connecting. A deadline timer wakes the mux on connection
timeout. `write` copies and accepts one bounded buffer; later polling or I/O reports
transmission failures. Enabling read interest starts TCP reads once connected.
UDP receive callbacks queue complete datagrams and drop new packets on overflow.
`buf_size` bounds buffered input and individual writes. Cleanup cancels pending
operations; UDP callbacks retain no reference to the freed socket handle.

`SocketOptions.configure` runs synchronously after socket creation and before
connecting, with the supplied context and reachability metadata. Its descriptor
encodes the bridge socket pointer; `pp_winrt_socket_get_transport` exposes the
borrowed WinRT transport for VpnChannel association. Returning false aborts open
and closes the socket. Reception is not yet handed over to `Decapsulate`.
The Windows platform socket factory selects this wrapper and
returns its borrowed manual-reset Windows event as `muxDescriptor`. Async
completions publish readiness under the same mutex used to reset the event;
read/write interest masks suppress unwanted wakes. Windows builds without the
bridge report `LinkNotActive`. Other platforms retain the portable socket wrapper.
