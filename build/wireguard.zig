// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const Run = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub const Bridge = struct {
    library: LazyPath,
    step: *std.Build.Step,
    runtime: ?LazyPath = null,
    runtime_name: ?[]const u8 = null,
};

pub fn appleSDK(b: *std.Build, target: std.Target) []const u8 {
    const simulator = target.abi == .simulator;
    const sdk = switch (target.os.tag) {
        .macos => "macosx",
        .ios => if (simulator) "iphonesimulator" else "iphoneos",
        .tvos => if (simulator) "appletvsimulator" else "appletvos",
        else => @panic("Unsupported WireGuard Apple target"),
    };
    return std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", sdk, "--show-sdk-path" }), "\r\n ");
}

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, sdk: ?[]const u8) Bridge {
    const t = target.result;
    const apple = t.os.tag.isDarwin();
    const windows = t.os.tag == .windows;
    const android = t.abi.isAndroid();
    const go_arch = switch (t.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
        else => @panic("Unsupported WireGuard architecture"),
    };
    const go_os = switch (t.os.tag) {
        .macos => "darwin",
        .ios, .tvos => "ios",
        .windows => "windows",
        .linux => if (android) "android" else "linux",
        else => @panic("Unsupported WireGuard platform"),
    };
    const go = b.findProgram(&.{"go"}, &.{}) catch @panic("WireGuard requires Go on PATH");
    const source = b.pathFromRoot("src/wireguard/go");
    // Resolve the module's selected Go toolchain, including automatic upgrades.
    const metadata = b.run(&.{ go, "-C", source, "env", "-json", "GOROOT", "GOVERSION", "GOFLAGS", "GOEXPERIMENT", "GOTOOLCHAIN", "GOAMD64", "GOARM64", "GOFIPS140", "GOWORK", "CGO_CFLAGS", "CGO_CPPFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS" });
    const parsed = std.json.parseFromSlice(std.json.Value, b.allocator, metadata, .{}) catch @panic("Invalid Go environment");
    const env = parsed.value.object;
    const host_goroot = env.get("GOROOT").?.string;

    const run = if (apple) b.addSystemCommand(&.{ "sh", "-c", "export GOROOT=$(cd \"$1\" && pwd -P); shift; exec \"$@\"", "build-wireguard" }) else Run.create(b, "build WireGuard Go bridge");
    if (apple) {
        const prepare = b.addSystemCommand(&.{
            "sh",               "-c",
            \\set -eu
            \\rsync -a --exclude=pkg/obj/go-build "$1/" "$3/"
            \\patch -p1 -f -N -d "$3" < "$2"
            ,
            "patch-go-runtime",
        });
        prepare.addDirectoryArg(.{ .cwd_relative = host_goroot });
        prepare.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ host_goroot, "VERSION" }) });
        prepare.addFileArg(b.path("src/wireguard/go/goruntime-boottime-over-monotonic.diff"));
        const runtime = prepare.addOutputDirectoryArg("goroot");
        prepare.setName("prepare WireGuard Go runtime");
        run.addDirectoryArg(runtime);
    }
    run.addArgs(&.{ go, "build", "-trimpath", "-ldflags", if (apple or windows) "-w" else "-w -extldflags=-Wl,-soname,libwg-go.so", if (apple) "-buildmode=c-archive" else "-buildmode=c-shared", "-o" });
    const name = if (apple) "libwg-go.a" else if (windows) "wg-go.dll" else "libwg-go.so";
    const output = run.addOutputFileArg(name);
    run.setCwd(b.path("src/wireguard/go"));
    run.setName("build WireGuard Go bridge");
    // Run hashes its explicit environment. Exclude transient Xcode/shell variables
    // while preserving the paths and settings Go needs for module downloads.
    run.clearEnvironment();
    for ([_][]const u8{ "PATH", "HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "SystemRoot", "SYSTEMROOT", "TEMP", "TMP", "TMPDIR", "GOPATH", "GOCACHE", "GOMODCACHE", "GOENV", "GOPROXY", "GOSUMDB", "GOPRIVATE", "GONOPROXY", "GONOSUMDB", "GOINSECURE", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR", "DEVELOPER_DIR" }) |key| {
        if (b.graph.environ_map.get(key)) |value| run.setEnvironmentVariable(key, value);
    }
    run.setEnvironmentVariable("PARTOUT_GO_TOOLCHAIN", metadata);
    run.setEnvironmentVariable("CGO_ENABLED", "1");
    run.setEnvironmentVariable("GOOS", go_os);
    run.setEnvironmentVariable("GOARCH", go_arch);
    for ([_][]const u8{ "GOFLAGS", "GOEXPERIMENT", "GOTOOLCHAIN", "GOAMD64", "GOARM64", "GOFIPS140", "GOWORK", "CGO_CPPFLAGS" }) |key| {
        run.setEnvironmentVariable(key, env.get(key).?.string);
    }
    const cc_option = b.option([]const u8, "wg-go-cc", "C compiler executable for cgo (non-Windows).");
    const flags_option = b.option([]const u8, "wg-go-cflags", "Target/sysroot flags for cgo (non-Windows).");
    var flags: []const u8 = flags_option orelse "";
    if (windows) {
        run.setEnvironmentVariable("CC", b.fmt("\"{s}\" cc -fno-sanitize=undefined -target {s}-windows-gnu", .{ b.graph.zig_exe, @tagName(t.cpu.arch) }));
        run.setEnvironmentVariable("PARTOUT_CC_VERSION", b.run(&.{ b.graph.zig_exe, "version" }));
    } else {
        const cc_name = cc_option orelse b.graph.environ_map.get("CC") orelse if (apple) "clang" else "cc";
        if (android and cc_option == null) @panic("Android WireGuard builds require -Dwg-go-cc and -Dwg-go-cflags for the NDK");
        const cc = b.findProgram(&.{cc_name}, &.{}) catch @panic("Cannot find the cgo C compiler");
        run.setEnvironmentVariable("CC", b.fmt("\"{s}\"", .{cc}));
        run.setEnvironmentVariable("PARTOUT_CC_VERSION", b.run(&.{ cc, "--version" }));
        if (apple) {
            const arch = if (t.cpu.arch == .aarch64) "arm64" else "x86_64";
            const version = t.os.version_range.semver.min;
            flags = b.fmt("{s} -isysroot \"{s}\" -target {s}-apple-{s}{f}{s}", .{ flags, sdk.?, arch, @tagName(t.os.tag), version, if (t.abi == .simulator) "-simulator" else "" });
            run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ sdk.?, "SDKSettings.json" }) });
        }
    }
    for ([_][]const u8{ "CGO_CFLAGS", "CGO_CXXFLAGS", "CGO_LDFLAGS" }) |key| {
        run.setEnvironmentVariable(key, b.fmt("{s} {s}", .{ env.get(key).?.string, flags }));
    }
    addSources(b, run, "src/wireguard/go");
    run.addFileInput(b.path("build/wireguard.zig"));
    run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ host_goroot, "VERSION" }) });

    const bridge: Bridge = if (windows) blk: {
        const dlltool = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", if (t.cpu.arch == .aarch64) "arm64" else "i386:x86-64", "-d" });
        dlltool.addFileArg(b.path("src/wireguard/go/exports.def"));
        dlltool.addArg("-l");
        const implib = dlltool.addOutputFileArg("wg-go.lib");
        dlltool.step.dependOn(&run.step);
        break :blk .{ .library = implib, .step = &dlltool.step, .runtime = output, .runtime_name = name };
    } else if (apple) .{ .library = output, .step = &run.step } else .{ .library = output, .step = &run.step, .runtime = output, .runtime_name = name };
    return bridge;
}

// Enumerate the source tree so additions and removals change the cache key too.
fn addSources(b: *std.Build, run: *Run, path: []const u8) void {
    var dir = std.Io.Dir.openDirAbsolute(b.graph.io, b.pathFromRoot(path), .{ .iterate = true }) catch @panic("Cannot read Go sources");
    defer dir.close(b.graph.io);
    var names: std.array_list.Managed([]const u8) = .init(b.allocator);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch @panic("Cannot enumerate Go sources")) |entry| {
        if (entry.kind == .file and (std.mem.endsWith(u8, entry.name, ".go") or std.mem.endsWith(u8, entry.name, ".c") or std.mem.endsWith(u8, entry.name, ".h") or std.mem.endsWith(u8, entry.name, ".s") or std.mem.startsWith(u8, entry.name, "go.") or std.mem.endsWith(u8, entry.name, ".diff"))) {
            names.append(b.dupe(entry.name)) catch @panic("OOM");
        } else if (entry.kind == .directory and std.mem.eql(u8, entry.name, "include")) {
            // Headers retain the wg_go namespace used by C callers.
            addSources(b, run, b.fmt("{s}/include/wg_go", .{path}));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.less);
    for (names.items) |name| run.addFileInput(b.path(b.fmt("{s}/{s}", .{ path, name })));
}
