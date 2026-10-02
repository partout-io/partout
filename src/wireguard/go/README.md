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

CMake orchestrates the Go bridge and the Zig/C library:

```sh
cmake -S . -B .cmake -DPP_BUILD_USE_WIREGUARD=ON
cmake --build .cmake
cmake --build .cmake --target partout-test
```

Use `--target partout-wg-go-build` to build only the bridge. The build rules in
`cmake/wg-go.cmake` track source files, ABI headers, module pins, and
configured compiler settings. Unchanged builds skip Go entirely. Reconfigure
CMake after changing toolchains or Go environment settings.

Apple uses Clang and a cached copy of Go with the sleep-aware runtime patch.
Zig embeds the resulting archive in Partout's static or shared library.
Windows uses `zig cc` and `zig dlltool`; Android and Linux use CMake's configured
C compiler. Their Go runtime libraries are installed alongside Partout.

For direct Zig development, pass the CMake-built library with `-Dwg-go-lib`
(the import `.lib` on Windows). Zig consumes that library without invoking Go
or CMake. `-Dwireguard=true` alone compiles with the stub C backend.
