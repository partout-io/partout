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
