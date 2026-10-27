# Windows WinRT backend

Windows support is experimental. The backend has carried traffic in manual
VPN-host testing; this is not yet production or full platform-parity
validation. The transport paths below are the default implementation, with no
separate experiment flag.

The native backend owns WinRT objects and a single command worker for setup,
writes and handover. Received packets and failures enter the existing daemon mailbox.
Zig owns protocol processing, backpressure and timers:

```text
VPN plugin -> partout_winrt.h -> src/runtime.cc -> Partout public API
                                              -> Partout::TunnelController
Partout io_windows.zig       -> winrt/abi.h -> src/abi.cc
Partout looper_windows.zig   -> winrt/abi.h -> src/abi.cc
Partout portable controller  -> src/platform.cc -> src/tun.cc
```

## Where code belongs

| Location | Responsibility |
| --- | --- |
| `include/partout_winrt.h` | Plugin-facing C++ runtime API; depends on `partout.h`. |
| `include/winrt/abi.h` | Native I/O boundary for transport capabilities, the loop and link setup; no socket or TUN object ABI. |
| `include/winrt/log.h` | Native logging boundary. |
| `src/runtime.cc` | Integrates VPN plugin callbacks with Partout; the only native source importing the Partout API. |
| `src/socket.h`, `src/socket.cc` | Private `Partout::Socket`, owning UDP/TCP transports, callbacks, reads, writes and callback lifetime. |
| `src/tun.h`, `src/tun.cc` | Private `Partout::TunnelController`, transport association and channel startup/stop. |
| `src/loop.h`, `src/loop.cc` | Persistent native command worker; no output queue or timer scheduler. |
| `src/abi.h`, `src/abi.cc` | C ABI loop handles, endpoint ownership and scheduling, address conversions, native socket policy tokens and link setup. |
| `src/platform.cc` | Implements Partout's portable controller and socket policy interfaces directly in C++. |
| `src/tun_settings.h`, `src/tun_settings.cc` | Negotiated IP/DNS settings mapping and validation. |
| `src/log.cc` | Optional process-wide logging callback, with a debugger-output fallback. |
| `../../src/net/io_windows.zig` | Native setup completions and transport capabilities, including passive subscriptions. |
| `../../src/net/looper_windows.zig` | Owns Zig timers and feeds the existing daemon I/O callbacks. |
| `../../src/c/portable/tun_windows.c` | Fallback controller stubs for builds without WinRT. |

`partout-winrt-backend` compiles sockets, the controller and logging with only
the native include directory. `partout-winrt` adds `runtime.cc`, `platform.cc` and packages all
objects into one archive for Zig. The backend has no portable ABI dependency.

## Logging

Native messages use `Partout::<Class>: action` prefixes and lowercase action
wording. Failures include `HRESULT=0x...` when available; packet sizes and
counters use named fields. Debug covers setup details and callback traces;
info covers channel/connection lifecycle, TCP EOF and packet totals; notice
covers unsupported requested features; error covers failed operations. Routine
snapshot and environment publication stubs remain debug traces to avoid repeated
notices. Fault is reserved for unrecoverable internal failures.

Runtime messages go to both channel diagnostics and the configured host logger;
the host logger receives the original level. A connection failure is reported
once per destination, including its HRESULT.

## Socket lifecycle

Link setup creates, configures and opens a transport in one native operation.
For connected sockets, association happens before connect. The configuration
callback receives a temporary native policy token through `pp_socket_fd`.
It must not retain or dereference that token; it is not a Winsock handle.

UDP uses the OS `MessageReceived` event. TCP owns an `IAsyncAction` read loop;
channel takeover cancels native I/O and joins that task directly.
Both deliver buffers or errors to the registered callback and borrowed context.
Clearing the callback drains delivery; callbacks consume or copy input and must not
reenter socket APIs. Receive buffers are borrowed until return. Writes copy the
packet and destination; one coroutine drains the native queue in FIFO order using
`co_await` for output-stream acquisition and writes. Success means accepted, with
later failures routed through the same callback. Channel-buffer writes copy into
VpnChannel's pool directly. See `include/winrt/abi.h` for the boundary contract.
Callers serialize writes with other writes, socket configuration, channel
takeover, writer replacement and destruction. The caller supplies this serialization.
Stopping writes and clearing receive callbacks may overlap an admitted write;
the owner keeps the socket alive until submission returns. Outstanding reads and
writes retain shared I/O state and native transports, without retaining Socket.

### Connected transports

The native transport invokes `ConnectionDaemon.onPacketsReceived()` directly.
The callback copies borrowed input into the existing daemon mailbox.
The actor dispatches through the existing I/O callbacks to `Connection.submitPackets()`.
There is no intermediate C++ output queue or per-packet synchronous worker call.
The native socket owns the lifetime
of its OS callbacks and pending reads. Before channel startup, direct socket
writes are drained, then reads are stopped (pending TCP reads are cancelled
and drained), before transferring the transport to VpnChannel.

After startup, `Encapsulate` queues plain IP packets on the TUN side and
`Decapsulate` queues transport data on the link side. Neither waits for protocol
processing. TUN writes copy packets into channel receive buffers and call
`AppendVpnReceivePacketBuffer` / `FlushVpnReceivePacketBuffers`. Link writes use
the socket during negotiation, then the channel send-buffer append/flush APIs
after startup. This requires the channel append/flush APIs
(Windows build 20348 or later). Native setup, socket writes, channel startup and
teardown serialize on the same C++ worker. Writes and resumes post commands;
setup and lifecycle operations may use synchronous barriers. Protocol callbacks
remain on the daemon actor and can detach their own side. A generation token
rejects already-queued input after detach or replacement.

### Unconnected UDP

Unconnected UDP uses an application-owned socket bound to the network adapter
selected before channel startup. It keeps receiving source addresses through
`MessageReceived` and sends to each supplied destination with
`GetOutputStreamAsync`; VpnChannel never takes over this socket.

The controller associates a separate idle UDP socket with VpnChannel because
channel startup requires a transport. Its numeric destination is `192.0.2.1:9`
(TEST-NET-1), with no DNS lookup or application payload writes. This transport
does not represent a protocol peer and is closed when the controller stops.

`Encapsulate` forwards borrowed IP packets to the registered TUN receiver.
TUN writes return packets through the channel receive-buffer append/flush APIs.
Unconnected UDP bypasses `Decapsulate` and the channel send-buffer path.

### Timers

Zig owns timer nodes, deadlines, replacement and cancellation. `loopOnce()` waits
on the existing daemon mailbox event with a timeout for the earliest timer.
Native callbacks wake that same event through the existing looper interface. Due tasks
and packet callbacks execute on the daemon thread; C++ has no timer scheduler.
Scheduling and cancellation are queue-confined, and timer tokens are copied by
value. Replacement preserves the old task on allocation failure; cancellation
and stop remove tasks before their borrowed contexts can be released. Tasks
scheduled by a timer callback become eligible on the next iteration.

The normal `loopOnce(null)` driver sleeps until packets, a mailbox wake, or a
timer deadline require work. Bounded waits remain available for tests. The
supplied mux is borrowed only for its wake event; a looper created without one
owns a private wake source. WindowsLooper has no receive FIFO: owned packets and
failures use the daemon's existing mailbox. Paused packets remain there without
blocking control messages or spinning; packet batches are bounded so timers run.
Packet submission allocation failure sets a terminal flag and wakes the daemon
actor to finalize and cancel; ordinary I/O failures retain protocol reconnect behavior.

### TUN lifetime and delivery

`TunnelController` exclusively owns the TUN `State`, including the channel and
packet counters. TUN handles and the socket writer borrow it; runtime shutdown
drains and destroys those transports before destroying the controller.
One receive mutex protects
the current borrowed TUN and serializes native packet delivery with callback
registration, removal and handle destruction. Freeing an old handle cannot clear
its replacement. Callbacks consume or copy input and must not reenter TUN or
controller APIs.

The Zig adapters hold generic owned capabilities, without native socket or TUN
types. Native classes use C++ types and borrow the runtime-owned `RuntimeLoop`; opaque
handles, C callback tables and address conversions stay in the ABI adapters.
Socket and TUN endpoints invoke the ABI receive adapter directly under their
delivery mutex. Callback removal drains that same gate; the ABI handle adds no
receive callback storage or second mutex. Each endpoint latches terminal errors
for subsequent writes, while TCP EOF remains a receive-only notification.
The native loop converts a write failure into the same queue used for
asynchronous receive/write failures.
Each ABI `TransportHandle` owns its socket or TUN directly and borrows the runtime
loop. It copies writes before posting them, schedules read resumes, and queues its
own destruction after immediately stopping writes and draining callbacks. There
is no intermediate C++ Transport object. Native socket policy tokens are opaque
ABI handle references, validated by the ABI adapter before channel association.
Detach drains native callbacks. Already-enqueued packets carry generation
tokens and are discarded during mailbox dispatch after detach or replacement.

Pausing TUN reads preserves already queued packets but drops new packet input
before allocation until reads resume. Errors remain eligible while paused.
Socket input retains in-flight TCP bytes until resume; native socket callbacks
provide backpressure.

WireGuard's passive I/O subscribes directly to a transport capability. Its
thread-safe Go read bridge consumes native producer callbacks independently of
the daemon loop, preserving per-peer source addresses, destination-aware writes,
quiesce/reactivation and callback draining during replacement. The protocol's
bounded queue for pending Go reads stays separate from daemon dispatch.

Writes copy the submission before posting it to the native worker. Channel
buffer operations then run on that worker, serialized with handover and stop.
Stop and callback removal do not wait behind link preparation. Final release
drains native receive callbacks immediately and queues destruction after accepted
commands. Channel close is queued while the runtime retains the controller. Worker
drainage stays on the destroying caller, outside the daemon actor.

`ConnectionWorker` selects its executor internally: RuntimeLoop on Windows
with WinRT enabled, or a Zig actor otherwise. Its request, completion and
factory contracts are shared across platforms. Shared endpoint
preparation runs on the C++ RuntimeLoop thread; the socket factory reuses that
loop for creation, association and open. No Zig preparation thread is started.
Workers, transports and the controller borrow the same loop for preparation,
writes, handover and teardown. Other
platforms keep `ConnectionWorker` and its Zig actor. Native input shares the
daemon's existing mailbox; protocol processing and timers remain in Zig.

## VPN channel runtime

C++ plugins include `partout_winrt.h` and construct `Partout::VpnChannelRuntime`
with a retained `VpnChannel`, profile JSON, logger settings and nonblocking
daemon options (`is_daemon = false`). The runtime copies the profile and cache
path. Serialize calls and forward the five `IVpnPlugIn` callbacks unchanged.
The runtime stops Partout before releasing the controller and transport.
`VpnChannelRuntime` exclusively owns the active loop. Stop joins the daemon actor
and drains accepted preparation, waits for plugin packet callbacks, destroys the
controller on the native worker after queued transport teardown, and drains and
joins that worker before releasing its WinRT apartment. Socket destruction also
waits for canceled read/write coroutines. Connect creates a fresh loop after Stop.
The process-wide loop lookup is borrowed and never extends this lifetime.
Standalone native consumers and tests must explicitly create a loop, release all
workers and transports, drain teardown, and free it; socket creation no longer
creates an implicit loop. Only one loop may be active, matching the daemon API.

CMake builds Partout as a shared library and installs `partout.h` and
`partout_winrt.h`. Plugins link Partout's import library with a compatible MSVC
runtime. Backend headers are internal integration interfaces, not installed
plugin headers.

Transport association, socket I/O and the TUN packet bridge are implemented.
Channel startup applies negotiated IP addresses, inclusion/exclusion routes,
DNS resolution rules and MTU from the remote IP/DNS modules. The receive pool
uses the negotiated MTU; the send pool adds 100 bytes for encapsulation.
Absent or zero MTU uses 1400 for all transports. Explicit MTUs are honored.
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
builds without WinRT use the fallback branch in `tun_windows.c` for
tests and builds that do not need native VPN support.
The Windows looper also requires the native archive; without it, creation
reports `MuxFailure`. Native dispatch tests run when WinRT is enabled.

Independent UDP is automatic for unconnected sockets; no additional
transport option is needed. The native archive alone does not register a VPN
plug-in or create a VPN profile; a packaged host must supply those.

The standalone settings mapping test uses real WinRT settings objects, without
a VPN host. From the same developer shell (adjust the archive path for your build):

```powershell
cl /std:c++20 /EHsc /MD /DNOMINMAX /Icross/windows/include tests/c/windows/tun_settings.cc /Fo.cmake-winrt/tun-settings-test.obj /Fe.cmake-winrt/tun-settings-test.exe .cmake-winrt/partout-winrt.lib windowsapp.lib runtimeobject.lib ws2_32.lib
& .cmake-winrt/tun-settings-test.exe
```
