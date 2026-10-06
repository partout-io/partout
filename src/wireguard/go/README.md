# WireGuard Go bridge

Partout owns this Go module and its C ABI in `include/wg_go`. The upstream
WireGuard implementation is a pinned Go dependency, not a vendored source tree.
Update the bridge, ABI headers, and callers under `src/wireguard` together.

Imported from `partout-io/prebuilts`, `vendors/wg-go`, on `master` at commit
`ba5c0895d873563beeab6974342b8ee0617a212e`. Existing source license notices are
preserved.

From the Partout repository root:

```sh
go -C src/wireguard/go test ./...
```

CMake builds the bridge when `PP_BUILD_USE_WIREGUARD` is enabled:

```sh
cmake -S . -B .cmake -DPP_BUILD_USE_WIREGUARD=ON
cmake --build .cmake --target partout-wg-go
cmake --build .cmake
```

The `partout` target depends on `partout-wg-go` and supplies the library through
Zig's existing vendor options. Zig does not build Go. Standalone
`zig build -Dwireguard=true` keeps its existing behavior, with ABI headers
available from this module's `include` directory.

`cmake/wg-go.cmake` caches the bridge and the patched Apple Go runtime.
Windows uses `zig cc` and `zig dlltool`; Apple, Android, and Linux use the
configured C compiler. Reconfigure after changing compiler or Go environment
settings.

## Passive UDP and TUN transport

`wgTurnOnWithPassiveIO(settings, link, tun, context)` selects passive `conn.Bind`
and `tun.Device` implementations together. Go owns neither sockets nor a native
TUN descriptor. The ABI is declared by `include/wg_go/wg_go.h` and its included
`passive_io.h`. Existing `wgTurnOn` retains native Go I/O.

The host creates/configures its UDP socket first and supplies its actual bound
port. Both passive interfaces use batches of 16 on every platform.
This caps idle payload storage at 2 MiB while still
amortizing host handoffs. The ABI accepts up to 256 descriptors. UDP batches carry a
binary source per packet or one destination per output batch. Mapped IPv4
addresses are normalized. Local source/interface stickiness is not provided.
The host supplies the effective TUN MTU, without AF or virtio packet headers.
Changing MTU or listen port requires a device restart. Nonzero fwmarks are
rejected; the host configures routing and socket protection.

Partout v2 uses the borrowed-buffer callbacks required `read` and `write` in both
`wg_passive_link` and `wg_passive_tun`. A read callback supplies writable
`wg_read_packet` descriptors pointing directly into WireGuard's Go buffers.
A write callback supplies `wg_packet` descriptors pointing into its output
buffers. The host retains these descriptors and payloads until completion;
Go pins their storage and waits before returning from Bind/TUN Read/Write.
There are no intermediate payload copies or receive queues on this path.
The bridge still allocates request metadata and synchronizes worker handoffs.

Submission callbacks return promptly and never wait for the looper. Returning
`WG_IO_OK` accepts the request and obliges the host to call
`wgCompleteIO(request, count, status)` exactly once, including on cancellation.
Completion may run before submission returns. A rejected submission must never
complete. `count` is the completed prefix; only those read descriptors have
valid `size` and, for UDP, `source` fields. All pointers become invalid at
completion. An empty readiness read retains the request for the next attempt.

`connection_v2.zig` owns the Go handle, activation worker, and lifecycle state
on the daemon's looper. `internal/passive_io.zig` only manages borrowed requests;
its mutex serializes Go submission callbacks with looper admission changes.
The daemon owns all native transport.

Startup and endpoint refresh run on a worker while the looper services borrowed
writes: persistent keepalive and UAPI updates can send synchronously. An
activation timer waits for that worker before publishing connection success;
the statistics timer runs only while active. On shutdown:

1. Reject new requests and complete outstanding reads with `WG_IO_CLOSED`.
2. Detach native I/O, completing/cancelling all accepted writes.
3. Join any activation worker, then call `wgTurnOffWithPassiveIO` to join Go workers, then release the context.

Do not join Go on the looper while its workers are waiting for looper I/O.
Configuration and bind failures publish no borrowed requests. A failure after startup uses
the same quiesce/detach/join sequence. Handles are never reused, so stale lifecycle calls cannot affect a replacement
device.

The passive API has a separate handle registry from the native v1 API. Use
`wgGetConfigWithPassiveIO` for statistics/configuration reads and
`wgDisableRoamingWithPassiveIO` for the mobile roaming policy. Never pass passive
handles to native lifecycle/configuration functions (or vice versa): their
numeric values can overlap. The legacy Go implementation remains unchanged;
only logging and the underlying WireGuard dependency are shared.

Partout selects `connection_v2.zig` when daemon v2 is enabled, using the same
runtime selection as OpenVPN. The legacy `connection.zig` and adapter retain
native Go I/O. V2 connections never own transport: the connection requests an
unconnected UDP link, and the daemon creates/configures the socket, applies
reported tunnel settings, and attaches both descriptors to its looper. It also
owns detachment and native resource cleanup.

The daemon attaches the bridge's read-buffer providers. Go workers publish
buffer batches; looper reads fill them and release callbacks complete the Go
requests. With no available Go buffers, reads pause until the next batch is
published. Outgoing batches use the runtime's completion-based `writeBorrowed`
API. Shutdown quiesces submissions, detaches I/O, then joins Go. Windows selects the same v2
implementation; unfinished native I/O panics when invoked. The runtime log identifies this
implementation with `Using WireGuardConnection v2`.

Validation:

```sh
go -C src/wireguard/go test -race ./...
```

The tests include borrowed buffer lifetime, cancellation, close/reopen,
concurrency, binary endpoints, C callbacks, and real encrypted round trips through two Go
devices using passive IPv4 and IPv6 transports. On macOS, after building the
CMake `partout-wg-go` target, compile/run the C ABI smoke test (replace `.cmake`
with your CMake build directory):

```sh
cc -Isrc/wireguard/go/include src/wireguard/go/tests/passive_abi.c \
  .cmake/wg-go/lib/libwg-go.a -lresolv \
  -framework CoreFoundation -framework Security -o /tmp/passive-abi
/tmp/passive-abi
```

The connection transitions from stopped to activating to active. A network
path change requests replacement of only the daemon-owned UDP link. TUN,
tunnel settings and the connected status remain in place, so a path notification
caused by applying settings cannot trigger a settings/reconnect loop. Link reads
remain parked across detachment; link writes are rejected until reattachment,
while TUN I/O remains active. The replacement socket keeps the selected local
port. Only peer endpoints are updated (including fresh DNS64 resolution), on
the activation worker because UAPI can flush staged sends. Peer sessions and
counters survive; refresh transitions through activating to active without
publishing another established event. Activation, link replacement or I/O
failure, explicit stop, and terminal looper failure transition through stopping
to stopped, cancelling requests and closing Go. A failed refresh uses the normal
daemon reconnect path, so the next attempt starts a fresh device.
