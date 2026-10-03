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
port plus a `wg_write_link_fn` callback. Go calls that callback with encrypted
outgoing datagrams and binary destinations. The host copies/enqueues both before
returning. The callback can run concurrently on Go workers; it must not wait for
the looper or call back into WireGuard.

For incoming UDP, the host calls `wgReceiveDatagrams` with the tunnel handle,
payload descriptors, and source endpoints. The bridge copies them into a 256-packet queue and
returns immediately. `WG_IO_QUEUE_FULL` means the unaccepted suffix was dropped. Go's one
receive function serves both address families, with `BatchSize() == 1` initially.
The endpoint ABI uses IP bytes, host-order port/scope, and family 4 or 6; mapped
IPv4 addresses are normalized. Local source/interface stickiness is not provided.

The looper submits ingress through `wgReceiveDatagrams` and
`wgReceiveTunPackets`, using `wg_packet` pointer/length arrays and one source
endpoint per UDP packet. Each call accepts up to `WG_IO_MAX_BATCH` (256) packets;
larger looper batches are split without allocating staging buffers. Validation
covers the whole batch before any enqueue. `WG_IO_QUEUE_FULL` or `WG_IO_CLOSED`
can accept a prefix and discard the remainder: never retry a batch. Empty batches
are no-ops. One-element batches handle individual packets. This batches ABI ingress;
Go Bind/TUN reads and output callbacks still process one packet at a time.

`Bind.Open` activates a fresh queue and reports the host-selected port;
`Bind.Close` wakes readers, discards pending packets, and waits for active send
callbacks. Neither invokes host lifecycle operations or closes the host socket.
Synchronize old host reads before replacing a transport: tunnel handles identify
devices, not socket generations. Listen-port changes require a device restart.
Nonzero fwmarks are rejected; the host configures routing and socket protection.

For TUN input, the host calls `wgReceiveTunPackets` with raw IP packet descriptors. Go
copies it into a separate bounded 256-packet queue. For TUN output, Go invokes
`wg_passive_tun.write`; the host copies the decrypted packet before returning.
Both directions omit platform headers. TUN also uses `BatchSize() == 1`.
The host supplies the effective MTU at startup; changing it requires restarting
the device. Closing the Go device wakes readers and joins callbacks without
closing any host descriptor.

Serialize startup, configuration, and shutdown on the host. Start receive
submission only after publishing the handle returned by startup; send callbacks
may occur during startup. Keep the callback context alive until
`wgTurnOffWithPassiveIO` returns and host producers have been detached/joined.
Receive calls may race with shutdown and return `WG_IO_CLOSED`. Handles are not reused during the process
lifetime, so late packets cannot enter a replacement device.

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

The passive bridge only converts packets and queues writes. Daemon link reads
include source endpoints; tunnel reads contain raw IP bytes. Protocol lifecycle
and receive calls execute on the looper, while callbacks from Go workers copy
outgoing packets into looper writes. Shutdown joins Go callbacks before the
daemon detaches I/O. Better-path and I/O failures use normal daemon reconnection,
which replaces/protects the host socket and rebuilds peer endpoint resolution.
Windows selects the same v2 implementation; unfinished native I/O reports an
activation failure instead of falling back to Go-owned transport. The runtime
log identifies this implementation with `Using WireGuardConnection v2`.

Validation:

```sh
go -C src/wireguard/go test -race ./...
```

The tests include queue ownership/overflow, close/reopen, concurrency, binary
endpoints, C receive entry points, and real encrypted round trips through two Go
devices using passive IPv4 and IPv6 transports. On macOS, after building the
CMake `partout-wg-go` target, compile/run the C ABI smoke test (replace `.cmake`
with your CMake build directory):

```sh
cc -Isrc/wireguard/go/include src/wireguard/go/tests/passive_abi.c \
  .cmake/wg-go/lib/libwg-go.a -lresolv \
  -framework CoreFoundation -framework Security -o /tmp/passive-abi
/tmp/passive-abi
```
