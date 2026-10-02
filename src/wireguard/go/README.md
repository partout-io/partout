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

CMake and the Apple XCFramework builder compile this source automatically.
Apple builds retain the sleep-aware Go runtime patch.

To build only the bridge locally:

```sh
cmake -S . -B .build/wg-go-local -DPP_BUILD_LIBRARY=OFF -DPP_BUILD_USE_WIREGUARD=ON
cmake --build .build/wg-go-local --target partout_wg_go_build
```

For direct Zig builds, use `-Dwg-go-include=src/wireguard/go/include` and
`-Dwg-go-lib=.build/wg-go-local/wg-go/lib`.

Windows builds use `zig cc` for cgo and `zig dlltool` for import libraries.
Apple, Android, and Linux retain their default C toolchains.

The Xcode XCFramework prebuild caches each Go archive under
`.build/wg-go/xcframework`. Unchanged sources, headers, Go/compiler settings,
SDK, and target reuse the archive without invoking Go. Source or build-input
changes rebuild the affected slice automatically.

Go sources live at the module root; the C ABI header stays under `include/wg_go`.
The Makefile supports Apple builds, including the patched Go runtime.
Windows, Android, and Linux builds use `cmake/wireguard-go.cmake` from the
repository root directly.
