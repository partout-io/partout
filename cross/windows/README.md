# Windows WinRT backend

Windows support is experimental. The backend has carried traffic in manual
VPN-host testing; this is not yet production or full platform-parity
validation. The transport paths below are the default implementation, with no
separate experiment flag.

The native backend owns WinRT objects and a single command worker for setup,
handover and teardown. Writes submit on their producer. OpenVPN receives run
inline when the execution gate is available; contention and failures use the
existing daemon mailbox. Zig owns protocol processing, backpressure and timers:

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
Clearing the callback drains delivery; callbacks consume or copy input and may
submit replies. Lifecycle APIs and callback removal must be deferred. Receive buffers are borrowed until return. Writes copy the
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
For OpenVPN, the callback tries the shared execution gate and invokes the existing
I/O callbacks and `Connection.submitPackets()` with borrowed input. There is no
payload copy, job allocation or actor wake for an uncontended packet. If controls,
timers, or another producer hold the gate, input is copied into the mailbox.
Per-side pending counts keep newer input from overtaking that fallback queue.
There is no intermediate C++ output queue or per-packet synchronous worker call.
The native socket owns the lifetime
of its OS callbacks and pending reads. Before channel startup, direct socket
writes are drained, then reads are stopped (pending TCP reads are cancelled
and drained), before transferring the transport to VpnChannel.

After startup, `Encapsulate` delivers plain IP packets on the TUN side and
`Decapsulate` delivers transport data on the link side. Both may process OpenVPN
synchronously, before Windows reclaims their borrowed buffers. TUN writes copy packets into channel receive buffers and call
`AppendVpnReceivePacketBuffer` / `FlushVpnReceivePacketBuffers`. Link writes use
the socket during negotiation, then the channel send-buffer append/flush APIs
after startup. This requires the channel append/flush APIs
(Windows build 20348 or later). Native setup, channel startup and teardown run
on the C++ worker. Writes submit directly under output gates; resumes post
commands. Setup and lifecycle operations may use synchronous barriers. Protocol
callbacks defer lifecycle changes to the actor. A generation token
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
Due tasks execute on the daemon thread under the execution gate; C++ has no
timer scheduler. Inline packet processing uses the same gate and wakes the actor
when scheduling or cancelling timers. Timer tokens are copied by value. Replacement preserves the old task on allocation failure; cancellation
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
its replacement. Callbacks consume or copy input and may submit output, but
must defer callback removal and controller lifecycle changes.

The Zig adapters hold generic owned capabilities, without native socket or TUN
types. Native classes use C++ types and borrow the runtime-owned `RuntimeLoop`; opaque
handles, C callback tables and address conversions stay in the ABI adapters.
Socket and TUN endpoints invoke the ABI receive adapter directly under their
delivery mutex. Callback removal drains that same gate; the ABI handle adds no
receive callback storage or second mutex. Each endpoint latches terminal errors
for subsequent writes, while TCP EOF remains a receive-only notification.
Synchronous submission failures return to the consumer; the daemon routes them
through its mailbox and the passive adapter reports failure to its owner.
The ABI uses separate `SocketHandle` and `TunHandle` owners. Each owns one endpoint
and borrows the runtime loop. Socket handling includes addresses, destination
validation and native read resumes; TUN handling includes only channel packet I/O.
Both submit writes on the producer and queue their own destruction after
immediately stopping writes and draining callbacks. Native socket policy tokens are opaque
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

Channel writes consume borrowed bytes synchronously without an intermediate
buffer or command. Asynchronous socket writes copy into a WinRT `Buffer` and
move it into the socket queue without a second payload copy. Zig and Go writer threads use the implicit MTA held alive
by the native worker and socket state. No thread hooks or per-packet apartment
setup are needed; runtime shutdown drains all I/O users before releasing the MTA.
Channel writes copy directly into channel-owned packet buffers on the producer,
serialized with channel close. Socket submission also excludes handover. TCP partial-write retries retain the
existing suffix-copy behavior.
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
handover and teardown. Other
platforms keep `ConnectionWorker` and its Zig actor. Native input uses the daemon's execution gate with mailbox fallback; protocol
processing and timers remain in Zig.

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
The controller subscribes to `NetworkInformation.NetworkStatusChanged` while
the daemon delegate is attached. It publishes initial physical-network
reachability and detects changes in adapter identity, including handoffs that
remain reachable throughout. Duplicate notifications for the same path are
ignored. Physical profile selection excludes VPN interfaces and covers Ethernet,
Wi-Fi and WWAN. When the preferred profile belongs to the VPN, physical default
routes are ranked by the sum of route and interface metrics, so a cheaper adapter
can replace one that remains connected. Profiles without default routes remain
available as a fallback for local networks. Reachability feeds the daemon connection gate; path changes
notify the daemon that the available physical path has changed. Replacement independent
UDP sockets select the current adapter even when the channel stays open.
Unsubscription drains delegate delivery before releasing its borrowed context.
Snapshot and environment publication remain unimplemented.

## Build

Requires CMake 4.0+, Visual Studio 2022 C++ tools, the Windows SDK, and the
`nlohmann_json` CMake package (for example, from vcpkg's `nlohmann-json` port).
Pass the package's toolchain file or prefix to CMake as needed. From the Partout
root in a developer shell matching the target architecture:

```powershell
cmake -S . -B .cmake-winrt -G Ninja -DCMAKE_BUILD_TYPE=Debug -DPP_BUILD_WINRT=ON -DPP_BUILD_LIBRARY=OFF
cmake --build .cmake-winrt --target partout-winrt
```

### OpenAPI models

Regenerate the entities in `cross/windows/src/models` with OpenAPI Generator
7.20.0 or newer, a Java 11+ JDK, and Python 3 (standard library only):

```sh
scripts/build.sh -gen-models cpp
```

If the installed CLI is older or its launcher does not expose
the JAR path, set `OPENAPI_GENERATOR_JAR` to a supported CLI jar.
The YAML reader reuses the parser bundled in that same JAR;
common launchers such as Homebrew's are detected automatically. There are no
Python package dependencies. The checked-in models need no generator at build
time.

Both generators use their stock templates: `cpp-pistache-server` produces value
structs with optional fields, and `cpp-httplib-server` produces discriminator
unions and their JSON decoders. Only model files and validation helpers are
retained; neither HTTP server library is a dependency. Runtime dependencies are
C++17 and nlohmann/json. Boost is not required.

`prepare-cpp-schema.py` projects inheritance-based discriminators into explicit
`oneOf` unions and normalizes identifiers consistently for both generators. It
leaves the shared schema and wire tags unchanged. `finish-cpp-models.py` applies
method naming, schema constant defaults/checks, optional null/reset handling,
and generic integer/validation
helpers from `src/json.h`. It does not generate discriminator dispatch or use
custom templates. Unknown discriminator tags are rejected by generated decoders.

```cpp
const auto profile = json.get<Partout::Models::TaggedProfile>();
const auto &ip = std::get<Partout::Models::TaggedModuleIp>(profile.modules.at(0));
const auto encoded = nlohmann::json(ip);
```

`TunSettings` consumes these typed variants and models, including DNS protocol
variants. Integer conversion rejects fractional or overflowing MTUs before
platform validation. Typed optional fields treat explicit null as absent;
arbitrary JSON payloads retain null as a JSON value. Sets use vectors with
generated uniqueness validation.

The portable model regression tests compile without the Windows SDK:

```sh
cmake -S tests/c/windows -B .cmake-models -G Ninja
cmake --build .cmake-models
ctest --test-dir .cmake-models --output-on-failure
```

### Native integration

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
a VPN host. From the same developer shell (adjust the archive and nlohmann/json
include paths for your build):

```powershell
cl /std:c++20 /EHsc /MD /DNOMINMAX /Icross/windows/include /Ipath/to/nlohmann/include tests/c/windows/tun_settings.cc /Fo.cmake-winrt/tun-settings-test.obj /Fe.cmake-winrt/tun-settings-test.exe .cmake-winrt/partout-winrt.lib windowsapp.lib runtimeobject.lib ws2_32.lib
& .cmake-winrt/tun-settings-test.exe
```

The network selection regression test covers simultaneous Wi-Fi and Ethernet
connectivity, route-cost preference, offline recovery and monitor lifecycle:

```powershell
cl /std:c++20 /EHsc /MD /DNOMINMAX tests/c/windows/network.cc /Fo.cmake-winrt/network-test.obj /Fe.cmake-winrt/network-test.exe .cmake-winrt/partout-winrt.lib windowsapp.lib runtimeobject.lib ws2_32.lib iphlpapi.lib
& .cmake-winrt/network-test.exe
```

## Packet-path diagnostics

Connect, run one speedtest, disconnect, and search the Info-level logs for
`IO metrics`. Reports are cumulative per daemon, native endpoint, or channel
lifetime and emitted at shutdown. No per-packet log messages are emitted.

Native writes now submit synchronously on the producer. Channel output copies
from the borrowed protocol packet directly into a VpnChannel buffer; it does not
allocate an intermediate WinRT Buffer or enqueue a RuntimeLoop command.
Independent socket output retains one owned WinRT Buffer for asynchronous I/O.
There is no additional packet pool or batch-collection delay. WireGuard preserves
existing Go write batches through the optional native batch capability. TUN output
flushes once after appending the submitted batch. Inline receive dispatch borrows one packet at a
time; fallback input uses one receipt per job.

- Daemon reports count accepted data packets, error receipts, dispatched packets,
  payload bytes, and dispatch wall time separately for link and TUN. Dispatch
  counts attempts, including stale receipts the looper discards. Historical
  batch field names remain comparable; dispatches are singletons. `created_batches`
  counts only queued data receipts. `inline_packets`, `queued_packets`, and
  `queued_bytes` show how often input bypasses allocation and actor handoff.
  `inline_dispatch_wall_ns` and `queued_dispatch_wall_ns` split total dispatch
  time by path; they include protocol processing and synchronous output, but not
  time spent waiting in the mailbox.
- `socket.submitted` and `tun.submitted` count direct submissions and payload
  bytes. They replace the former `dequeued` worker-command counters. Their batch
  sizes reflect existing Go submissions; scalar callers remain singletons. `tun.stopped` counts submissions rejected after stopping.
- `socket.copy_buffer` measures allocation and copying only for asynchronous
  socket output. Channel output has no intermediate copy. The former
  `tun.copy_buffer`, `socket.queue_wait`, and `tun.batch_queue_wait` stages are
  absent because those operations have been removed.
- `socket.write_submit_not_completion` includes synchronous channel submission
  and flushing, or direct-socket copying/enqueueing. `tun.write_submit` includes
  channel buffer preparation, copying, appending, and flushing. Both include
  waiting for their output serialization gate.
- `socket.output_stream_success_wall` and `socket.write_async_success_wall`
  include asynchronous waits and record successful returns only.
- `channel.tun` is downstream; `channel.link` is upstream. Buffer acquisition,
  copy/length adjustment, append, and flush timings include failed/throwing calls.
  Callback timings exclude waiting for the receive mutex.

Times are elapsed wall time, not CPU time. Nested stages overlap and must not be
summed as independent costs. Compare totals normalized by packet/byte counts
under matched traffic. Pool and deferred batch-flush counters from the removed
performance experiments are intentionally absent.

The standalone metric regression verifies units, counts, maxima, and scope
timing on exceptions. Run from a Visual Studio developer shell:

```powershell
cl /std:c++17 /EHsc /MD /UNDEBUG /Icross/windows/src /Icross/windows/include tests/c/windows/io_metrics.cc /Fo.zig-cache/io-metrics-test.obj /Fe.zig-cache/io-metrics-test.exe
& .zig-cache/io-metrics-test.exe
```

## Direct output ownership and threading

The native worker owns setup, association, takeover, and teardown. The OpenVPN
actor or WireGuard output caller owns each synchronous ABI write. Owners must
serialize writes with descriptor release. Socket submission excludes takeover;
channel submission excludes channel close. Stop remains atomic. Close disables
channel submission and waits for the active write before stopping VpnChannel.
Submission errors return to the consumer, which dispatches lifecycle failures;
the submission path does not invoke receive callbacks for synchronous errors.
Asynchronous socket failures still use the registered receive callback.

OpenVPN receive callbacks process borrowed input inline under `ExecutionGate`.
Actor controls and timer dispatch acquire the same gate; the actor releases it
while waiting for I/O. Native producers never wait for this gate: they enqueue
owned input when it is busy, when older receipts remain queued on that side, or
when a link is paused. Failures are always queued to avoid protocol reentrancy.
Waiting controls have priority over new inline admission. Native callbacks may
submit synchronous replies, but lifecycle events remain deferred to the actor.
This prevents native callback drainage from waiting on protocol work that is in
turn waiting for the actor. Timer changes wake the actor to recompute deadlines.

WireGuard retains its passive reader adapter and Go crypto workers. POSIX
transports and protocol interfaces are unchanged. The native socket delivery
mutex allows same-thread reply submission; nested receive notifications fall
back to the mailbox because the protocol execution gate is already held.

The native output regression verifies borrowed channel bytes on the caller,
stop rejection, asynchronous payload ownership, socket transmission while
the command worker is blocked, and real UDP replies from a receive callback.
The Windows daemon test covers allocation-free borrowed receives, ordered
contention fallback, native-scheduled timers, and stop racing an active receive. Link against the matching WinRT archive:

```powershell
cl /std:c++20 /EHsc /MD /UNDEBUG /DNOMINMAX /Icross/windows/src /Icross/windows/include tests/c/windows/socket_output.cc /Fo.zig-cache/socket-output-test.obj /Fe.zig-cache/socket-output-test.exe path/to/partout-winrt.lib windowsapp.lib runtimeobject.lib ws2_32.lib iphlpapi.lib ole32.lib
& .zig-cache/socket-output-test.exe
```

## WireGuard native batches and UDP cache

The Windows transport has optional `write_batch` and `subscribe_batch` callbacks.
Packet descriptors and payloads are borrowed only until callback return, with a
maximum of 256 packets per call. Both sides of this private ABI must be rebuilt
together. Older test producers can leave these capabilities null and use scalar
fallback. No wireguard-go sources or Go ABI contracts change.

Go output batches reach the native TUN as one call: acquire/copy/append each
channel buffer, then flush once. Errors report the accepted prefix and flush any
already appended buffers before returning failure. Socket output retains one
WinRT buffer per datagram for asynchronous completion; batches never concatenate
UDP datagrams. Native socket submission takes its write gate once per batch.

Independent UDP caches at most 64 endpoint objects, keyed by family, address,
port, and IPv6 scope. Each entry retains its HostName/service and lazily acquired
output stream. Eviction drops the oldest cache reference; queued writes retain
their own entry. Replacing the transport replaces its cache, so streams cannot
survive a physical adapter rebind. Terminal errors still stop the transport.

VpnChannel input lists are delivered to the passive adapter in chunks of at
most 256 borrowed packet views. Each chunk holds the adapter lock once, fills
waiting Go reads, queues only the remainder, and notifies readers once if any
were filled or interrupted. It never waits to accumulate a batch. The existing
1024-packet drop-newest queue remains; no speculative reusable pool is added.

For matched speedtests, inspect these additional counters:

- `socket.endpoint_cache`: hits, misses, and retained entries. Before caching,
  unconnected output-stream requests are all misses and retained entries are zero.
- Passive input: batches, packets, maximum batch size, and reader notifications.
- `direct_packets` / `direct_bytes`: input copied straight into pending Go reads.
- `queued_packets` / `queued_bytes`: fallback packets needing owned storage.
- `queue_peak`, `queue_full_drops`, `oversized_drops`, and `allocation_failures`.

Counters are cumulative per passive adapter or socket lifetime. Queue counters
measure successful enqueues; they do not count packets still pending at shutdown.
The baseline queue uses separate node and payload allocations. Use its measured
queued fraction to decide whether reducing fallback allocations is worthwhile.
For downstream traffic, compare `tun.submitted` batch sizes with
`channel.tun.flush` calls and normalize CPU/time by bytes transferred.
