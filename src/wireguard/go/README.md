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

Zig owns compilation, caching, linking, and installation of the bridge:

```sh
zig build wg-go -Dwireguard=true
zig build install -Dwireguard=true
```

The build helper is `build/wireguard.zig`. It tracks Go sources, C ABI headers,
module pins, toolchain settings, and the target SDK. Apple builds use a cached
copy of Go with the sleep-aware runtime patch. Changes invalidate the relevant
Zig build steps; unchanged builds reuse the generated library.

Apple builds embed the Go archive in Partout's static or shared library.
Windows uses `zig cc` and `zig dlltool`, installing `wg-go.dll` in `bin` and
its import library in `lib`. Linux and Android install `libwg-go.so` in `lib`.

For Android or Linux cross-compilation, pass the platform compiler executable
with `-Dwg-go-cc` and its target/sysroot flags with `-Dwg-go-cflags`. CMake
supplies these from its configured toolchain. Apple uses Clang and the Xcode SDK.
