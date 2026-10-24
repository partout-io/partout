# Windows WinRT backend

Windows support is experimental. OpenVPN and WireGuard have carried traffic in
manual VPN-host testing; this is not yet production or full platform-parity
validation. The transport paths below are the default implementation, with no
separate experiment flag.

The native backend owns WinRT objects and asynchronous I/O. Partout owns the
portable ABI adapters. Dependencies run from Partout to the backend:

```text
VPN plugin -> partout_winrt.h -> src/runtime.cc -> Partout public API
                                              -> PartoutTunnelController
Partout io_windows.zig       -> winrt/socket.h  -> src/socket.cc
Partout portable/tun_winrt.c -> winrt/tun.h     -> src/tun_ctrl.cc
```

## Where code belongs

| Location | Responsibility |
| --- | --- |
| `include/partout_winrt.h` | Plugin-facing C++ runtime API; depends on `partout.h`. |
| `include/winrt/` | Backend-owned socket, tunnel controller and logging interfaces; no Partout headers. |
| `src/runtime.cc` | Integrates VPN plugin callbacks with Partout; the only native source importing the Partout API. |
| `src/socket.cc` | Owns UDP/TCP transports, receive callbacks, TCP read loop, writes and callback lifetime. |
| `src/tun_ctrl.h`, `src/tun_ctrl.cc` | Private `PartoutTunnelController`, transport association and channel startup/stop. |
| `src/log.cc` | Optional process-wide logging callback, with a debugger-output fallback. |
| `../../src/net/io_windows.zig` | Partout socket and TUN wrappers. |
| `../../src/net/looper_windows.zig` | Queued packet callbacks, attachment lifetime and timers; ignores the shared mux option. |
| `../../src/wireguard/internal/passive_io_windows.zig` | Queues native receives for Go's passive read callbacks and forwards writes. |
| `../../src/c/portable/tun_winrt.c` | Converts Partout's portable controller ABI into backend calls. |

`partout-winrt-backend` compiles sockets, the controller and logging with only
the native include directory. `partout-winrt` adds `runtime.cc` and packages all
objects into one archive for Zig. The backend has no portable ABI dependency.

## Socket lifecycle

Create a socket, configure it through the tunnel controller, then open it.
For connected sockets, association must happen before connect. The Partout adapter passes
the opaque socket pointer through `pp_socket_fd`; it is not a Winsock handle.

UDP uses the OS `MessageReceived` event. TCP runs an asynchronous read loop.
Both deliver buffers or errors to the registered callback and borrowed context.
Clearing the callback drains delivery; callbacks only queue input and must not
reenter socket APIs. Buffer contents are borrowed until return. Writes wait for WinRT's
asynchronous operation to complete. See `include/winrt/socket.h` for the contract.

### Connected transports (OpenVPN)

The WindowsLooper queues owned input for both link and TUN attachments and
dispatches their callbacks on its caller. The native socket owns the lifetime
of its OS callbacks and pending reads. Before channel startup, direct socket
reads are stopped (pending TCP reads are cancelled and drained).

After startup, `Encapsulate` queues plain IP packets on the TUN side and
`Decapsulate` queues transport data on the link side. Neither waits for protocol
processing. TUN writes copy packets into channel receive buffers and call
`AppendVpnReceivePacketBuffer` / `FlushVpnReceivePacketBuffers`. Link writes use
the socket during negotiation, then the channel send-buffer append/flush APIs
after startup. This requires the channel append/flush APIs
(Windows build 20348 or later). Detach drains input callbacks and rejects new
writes, while retained attachments let already admitted writes finish.

### Unconnected UDP (WireGuard)

WireGuard uses an application-owned UDP socket bound to the network adapter
selected before channel startup. It keeps receiving source addresses through
`MessageReceived` and sends to each supplied destination with
`GetOutputStreamAsync`; VpnChannel never takes over this socket.

The controller associates a separate idle UDP socket with VpnChannel because
channel startup requires a transport. Its numeric destination is `192.0.2.1:9`
(TEST-NET-1), with no DNS lookup or application payload writes. This transport
does not represent a WireGuard peer and is closed when the controller stops.

`Encapsulate` forwards IP packets into the passive TUN queue. Go workers read
the UDP and TUN queues through the passive ABI; decrypted packets return through
the channel receive-buffer append/flush APIs. WireGuard does not use
`Decapsulate` or the channel send-buffer path for its UDP traffic.

The passive implementation is split into POSIX and Windows backends, with shared
argument validation and endpoint conversion. Local tests cover multiple UDP
sources and replying after a source-port change. Live multi-peer/peer-roaming,
background suspension and resume still need validation. The physical adapter is
retained across UDP bind replacement; automatic local-interface migration is not
implemented.

### Timers

Timers use one `RunAfter` alarm for the earliest pending deadline. The alarm
only wakes the looper; `loopOnce()` invokes due tasks on its caller thread.
Scheduling and cancellation are queue-confined, and timer tokens are copied by
value. Replacement preserves the old task on allocation failure; cancellation
and stop remove tasks before their borrowed contexts can be released. Tasks
scheduled by a timer callback become eligible on the next iteration.

The normal `loopOnce(null)` driver remains nonblocking so its caller can service
the separate mailbox. Explicit bounded polls can wait for the timer alarm.

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

Transport association, socket I/O and the TUN packet bridge are implemented.
Channel startup applies negotiated IP addresses, inclusion/exclusion routes,
DNS resolution rules and MTU from the remote IP/DNS modules. The receive pool
uses the negotiated MTU; the send pool adds 100 bytes for encapsulation.
Absent or zero MTU uses 1400 for connected transports and 1420 for independent
UDP, matching WireGuard passive I/O's default. Explicit MTUs are honored.
Default inclusion routes are split into two `/1` routes to outrank physical
default routes without relying on interface metrics. Absent IP families are
passed to Windows as `nullptr`, not empty address lists.
Route gateways and DNS search suffix lists have no corresponding
channel setting. Encrypted DNS is rejected rather than silently downgraded.
Controller notifications remain unimplemented.

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

Enable WireGuard with `-DPP_BUILD_USE_WIREGUARD=ON` when building the full
library. Independent UDP is automatic for unconnected sockets; no additional
transport option is needed. The native archive alone does not register a VPN
plug-in or create a VPN profile; a packaged host must supply those.

The standalone settings mapping test uses real WinRT settings objects, without
a VPN host. From the same developer shell (adjust the archive path for your build):

```powershell
cl /std:c++20 /EHsc /MD /DNOMINMAX /Icross/windows/include tests/c/windows/tun_settings.cc /Fo.cmake-winrt/tun-settings-test.obj /Fe.cmake-winrt/tun-settings-test.exe .cmake-winrt/partout-winrt.lib windowsapp.lib runtimeobject.lib ws2_32.lib
& .cmake-winrt/tun-settings-test.exe
```
