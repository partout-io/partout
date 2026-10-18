# WireGuard Go bridge

This module exposes wireguard-go to Partout through the C ABI in `include/wg_go`.
The upstream implementation is a pinned Go dependency. Keep the bridge, ABI
headers, and callers under `src/wireguard` in sync when changing the interface.

The bridge was imported from `partout-io/prebuilts`, `vendors/wg-go`, at commit
`ba5c0895d873563beeab6974342b8ee0617a212e`. Existing source license notices are
preserved.

## Modes

**Active mode** uses standard wireguard-go and its original C ABI. Partout creates and configures the TUN device, then Go performs native TUN I/O and manages its own UDP sockets. The adapter retains the handed-off TUN, protects Go-created sockets where required, and refreshes them through the standard socket-bump functions. Peer hostnames are resolved before tunnel settings are applied. On platforms that suspend Go while offline, resume requests a replacement TUN before restarting the backend. This is the default WireGuard v2 mode on non-Windows platforms (`daemon_io = .none`).

**Passive mode** uses Partout's custom callback ABI, declared in [wg_go.h](include/wg_go/wg_go.h) and [passive_io.h](include/wg_go/passive_io.h). Partout owns UDP and TUN I/O; `wgTurnOnWithPassiveIO` supplies Go with read/write callbacks instead of native descriptors. Go lends pinned packet buffers to the host, which completes each accepted request through `wgCompleteIO`. Common operations reuse the original ABI, while passive shutdown and endpoint updates use dedicated functions. The C shim serializes device calls and dispatches according to the selected mode. Active and passive backends must never run concurrently, and previous-mode calls must finish before switching. This is the default WireGuard v2 mode on Windows (`daemon_io = .link`).

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
