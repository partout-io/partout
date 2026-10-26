# WireGuard Go bridge

This module exposes wireguard-go to Partout through the C ABI in `include/wg_go`.
The upstream implementation is a pinned Go dependency. Keep the bridge, ABI
headers, and callers under `src/wireguard` in sync when changing the interface.

The bridge was imported from `partout-io/prebuilts`, `vendors/wg-go`, at commit
`ba5c0895d873563beeab6974342b8ee0617a212e`. Existing source license notices are
preserved.

## Modes

**Active mode** uses standard wireguard-go and its original C ABI. Partout creates and configures the TUN device, then Go performs native TUN I/O and manages its own UDP sockets. The adapter retains the handed-off TUN, protects Go-created sockets where required, and refreshes them through the standard socket-bump functions. Peer hostnames are resolved before tunnel settings are applied. On platforms that suspend Go while offline, resume requests a replacement TUN before restarting the backend. This is the default WireGuard mode on non-Windows platforms (`daemon_io = .none`).

**Passive mode** uses Partout's custom callback ABI, declared in [wg_go.h](include/wg_go/wg_go.h) and [passive_io.h](include/wg_go/passive_io.h). Partout owns UDP and TUN I/O; `wgTurnOnWithPassiveIO` supplies Go with read/write callbacks instead of native descriptors. Go lends pinned packet buffers to the host, which completes each accepted request through `wgCompleteIO`. Common operations reuse the original ABI, while passive shutdown and endpoint updates use dedicated functions. The C shim serializes device calls and dispatches according to the selected mode. Active and passive backends must never run concurrently, and previous-mode calls must finish before switching. This is the default WireGuard mode on Windows (`daemon_io = .link`).

## Windows passive I/O

[The Windows passive adapter](../internal/passive_io_windows.zig) fills waiting
Go reads directly from native UDP and TUN callbacks under its receive lock.
This avoids queue allocations and an intermediate payload copy. Packets arriving
without a waiting reader use bounded owned queues. Read buffers are unregistered
before completion; detach, shutdown and failure cancel pending registrations.
Callbacks never complete Go requests themselves; the waiting Go worker completes
after releasing the receive lock. POSIX passive I/O instead reads directly from
descriptors with readiness waits; the production non-Windows path uses active mode.

The adapter serializes writes against descriptor replacement. Passive write
completion releases the Go buffer after the native backend copies it; it reports
acceptance rather than network transmission. Later socket failures use the
adapter's receive-error path.

WireGuard keeps its unconnected UDP socket outside VpnChannel transport takeover.
`Encapsulate` supplies TUN input, and decrypted packets return through the channel
receive-buffer append/flush APIs. WireGuard does not use `Decapsulate` or the
channel send-buffer path for UDP traffic. See the [Windows backend guide](../../../cross/windows/README.md#unconnected-udp)
for native transport setup.

Local tests cover allocation-free delivery to waiting readers, queued batches,
cancellation and buffer lifetimes, multiple UDP sources and replies after a
source-port change. Live multi-peer/peer-roaming, background suspension and resume
still need validation. The physical adapter is retained across UDP bind
replacement; automatic local-interface migration is not implemented.

## Build and test

CMake builds the Go bridge through the `partout-wg-go` target and passes its
library and headers to Zig. Zig does not build Go itself. From the repository
root:

```sh
cmake -S . -B .cmake -DPP_BUILD_USE_WIREGUARD=ON
cmake --build .cmake --target partout-wg-go
cmake --build .cmake
go -C src/wireguard/go test -race ./...
```
