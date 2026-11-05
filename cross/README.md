# Native runtimes

The Zig library publishes `partout.h`. Native runtimes supply a complete
`partout_daemon_bindings.controller_functions` table when starting a daemon.
Missing bindings or callbacks are rejected; there is no platform-controller
fallback. The core copies the table, detaches callbacks during teardown, and
then invokes `release`. Generated language models remain in the native SDKs.

Low-level I/O remains in the core. Apple’s runtime finds and duplicates the
NetworkExtension descriptor; Android’s runtime borrows its VPN service descriptor.
Both use `partout_tun_wrap_fd`: Apple passes `owned=true`, Android `owned=false`.
The POSIX runtime provides `partout_tun_open` for Linux/macOS devices and passes
`owned=true` to the core wrapper.

* Apple: SwiftPM's `PartoutRuntime` supplies callbacks directly. It needs only
  the public C header, without exported Swift callback names or symbol lookup.
* Android: `native/` under `cross/android` owns JNI entry points, JVM attachment,
  global references, and controller callbacks. CMake's `Partout::AndroidRuntime`
  object target is linked into the application's JNI shared library; it depends
  on `Partout::Partout`. The core does not contain JNI entry points.
* POSIX: `Partout::PosixRuntime` supplies the existing minimal TUN-only controller
  for command-line consumers. Routing and DNS configuration remain unimplemented;
  the extraction does not add those capabilities.
* Windows: `Partout::WindowsRuntime` supplies the plugin runtime and callback table.
  Its static library links separately from the core. Both use the private
  `partout-windows-backend.dll`, so native loop and transport state are not duplicated.
  Deploy that DLL alongside `partout.dll`. It is an implementation dependency,
  not an extension of the public core ABI.

Rebuild the core and runtimes together when changing the C bindings. Windows
consumers inherit the runtime's C++20 requirement through its CMake target.
Configure with `PP_TEST_RUNTIME_LINK=ON` to build the offline Windows linkage test,
then run CTest. That test checks separate linkage without changing VPN settings.
