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
buffers. Go pins their storage and waits before returning from Bind/TUN Read/Write.
There are no intermediate payload copies or receive queues on this path.

Returning `WG_IO_OK` accepts the request and requires exactly one
`wgCompleteIO(request, count, status)`. Completion may run inline before the
callback returns. A rejected submission must never complete. `count` is the
completed prefix; only those read descriptors have valid `size` and, for UDP,
`source` fields. All borrowed pointers become invalid at completion.

Partout's `internal/passive_io.zig` calls the owned descriptor interfaces directly
on Go workers and completes each attempt inline. Its mutex serializes native
calls with descriptor replacement and cleanup. Nonblocking reads with no data,
TUN calls before `commit()`, and write backpressure complete with `WG_IO_AGAIN`.
On POSIX, `POSIXInterface.waitForReadiness()` uses `net.Waiter` and the shared
mux poll helper on `WouldBlock`, releasing the bridge mutex while waiting. Link/TUN
workers share a mux wake and wait without a poll timeout. Commit, descriptor
replacement and adapter shutdown wake pending waits; before TUN commit, only wake
is watched. Backpressure keeps its bounded retry delay. Go uses no retry timer. Read retries cancel on Bind/TUN close; backend shutdown cancels write retries. Writes retry only the uncompleted suffix. The callback ABI
also continues to support asynchronous hosts that retain requests until completion.

Startup writes can run synchronously while `wgTurnOnWithPassiveIO` executes;
readers wait for successful startup before entering the callbacks. Shutdown
rejects new native requests, calls `wgTurnOffWithPassiveIO` to cancel retries and
join Go workers, then releases the descriptors and bridge context. Each native
call is nonblocking, and no packet request depends on a looper or native worker.
Handles are never reused, so stale lifecycle calls cannot affect a replacement
device.

The existing native Go functions are unchanged. Passive devices register in the
original handle map as well as a separate registry retaining their I/O state.
They use the original config getter and roaming functions, plus the common
`wgSendKeepalives` entry point. `wgTurnOffWithPassiveIO` removes both entries and
closes passive I/O. Passive handles are never reused. `wgSetEndpointsWithPassiveIO`
accepts only endpoint updates; full configuration, MTU, or listen-port changes
require restart.

Partout's C wrappers expose common operations to the single Zig backend vtable.
They serialize device calls to protect the original Go handle map, and remember
the mode selected by successful startup for shutdown and configuration updates.
I/O completion remains unlocked so callbacks can finish during device calls.
Direct Go ABI callers must serialize device calls themselves. Active and passive
backends must never run concurrently, and all calls from the previous mode must
finish before switching modes. Passive socket refresh is a no-op because the host
owns transport.

Partout selects `connection_v2.zig` when daemon v2 is enabled, using the same
runtime selection as OpenVPN. The legacy `connection.zig` and adapter retain
native Go I/O. V2 uses native Go I/O on non-Windows platforms
(`daemon_io = .none`) and passive transport on Windows (`daemon_io = .link`).
In link mode, the daemon creates/configures UDP and transfers it through `startV2()`.
WireGuard returns `.established` with owned tunnel info. The daemon applies tunnel
settings and transfers the TUN through `commit()` immediately in the same actor
turn, before processing queued reachability events.
Active mode caches peer hostname answers in `startV2()`, before returning
establishment and before the daemon applies tunnel settings. Commit maps the
cached numeric addresses for the current network and starts Go, preserving v1's
DNS/DNS64 ordering. Stopping before commit discards the cached answers.
Offline resume currently retains the committed TUN and restarts Go; reapplying
settings and replacing the TUN remains deferred.
The connection owns handed-off resources and cleans them up after backend shutdown.
Windows native descriptor I/O remains unimplemented. The runtime log identifies this
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
