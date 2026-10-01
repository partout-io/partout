# WireGuard Go bridge

Partout owns this Go module and its C ABI in `include/wg_go`. The upstream
WireGuard implementation is a pinned Go dependency, not a vendored source tree.
Update the bridge, ABI headers, and callers under `src/wireguard` together.

Imported from `partout-io/prebuilts`, `vendors/wg-go`, on `master` at commit
`ba5c0895d873563beeab6974342b8ee0617a212e`. Existing source license notices are
preserved.

From the Partout repository root:

```sh
go -C src/wireguard/go test ./src/...
scripts/build-wg-go-local.sh
```

CMake and the Apple XCFramework builder compile this source automatically.
Direct Zig builds accept the include and library paths printed by the local
build script. Apple builds retain the sleep-aware Go runtime patch.

Windows builds use `zig cc` for cgo and `zig dlltool` for import libraries.
Apple, Android, and Linux retain their default C toolchains.

The Xcode XCFramework prebuild caches each Go archive under
`.build/wg-go/xcframework`. Unchanged sources, headers, Go/compiler settings,
SDK, and target reuse the archive without invoking Go. Source or build-input
changes rebuild the affected slice automatically.
