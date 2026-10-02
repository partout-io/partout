// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const c_flags = &.{
    "-W",
    "-Wall",
    "-Wextra",
    "-pedantic",
    "-Werror",
    "-Wno-nullability-extension",
    "-fvisibility=hidden",
};

const Vendor = enum {
    openssl,
    mbedtls,

    fn optionName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "openssl",
            .mbedtls => "mbedtls",
        };
    }

    fn displayName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "OpenSSL",
            .mbedtls => "MbedTLS",
        };
    }

    fn frameworkName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "openssl",
            .mbedtls => "mbedtls",
        };
    }

    fn appleStaticArchiveName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "libopenssl.a",
            .mbedtls => "libmbedtls.a",
        };
    }
};

const VendorPaths = struct {
    vendor: Vendor,
    include: ?[]const u8,
    library: ?[]const u8,

    fn enabled(paths: VendorPaths) bool {
        return paths.include != null;
    }
};

const Vendors = struct {
    openssl: VendorPaths,
    mbedtls: VendorPaths,
    openssl_config_include: ?[]const u8,

    fn all(vendors: Vendors) [2]VendorPaths {
        return .{ vendors.openssl, vendors.mbedtls };
    }
};

const BuildConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    libc_installation: ?std.zig.LibCInstallation,
    apple_sdk_path: ?[]const u8,
    vendors: Vendors,
    winrt_library: ?std.Build.LazyPath,
    wg_go: ?std.Build.LazyPath,
    openvpn: bool,
    wireguard: bool,
    options: *std.Build.Step.Options,
};

const CBindings = struct {
    portable: *std.Build.Module,
    io: *std.Build.Module,
    crypto: *std.Build.Module,
    partout: *std.Build.Module,
    openvpn: ?*std.Build.Module,
    wireguard: ?*std.Build.Module,

    fn addImports(bindings: CBindings, module: *std.Build.Module) void {
        module.addImport("portable_c", bindings.portable);
        module.addImport("io_c", bindings.io);
        module.addImport("crypto_c", bindings.crypto);
        module.addImport("partout_c", bindings.partout);
        if (bindings.openvpn) |openvpn| {
            module.addImport("openvpn_c", openvpn);
        }
        if (bindings.wireguard) |wireguard| {
            module.addImport("wireguard_c", wireguard);
        }
    }
};

const default_api_excluded_schemas =
    "Address," ++
    "CustomModule," ++
    "Endpoint," ++
    "EndpointProtocol," ++
    "ExtendedEndpoint," ++
    "OpenVPN.CryptoContainer," ++
    "SecureData," ++
    "Subnet," ++
    "TaggedModuleCustom," ++
    "UniqueID," ++
    "WireGuard.Key";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .abi = if (builtin.os.tag == .windows) .msvc else null },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const strip = b.option(bool, "strip", "Omit debug information from emitted binaries.");
    const api_codegen_step = addAPICodegenStep(b);
    const shared = b.option(
        bool,
        "shared",
        "Build Partout as a shared library.",
    ) orelse false;
    const install_name = b.option(
        []const u8,
        "install-name",
        "Darwin install name for a shared Partout library.",
    );
    const use_openvpn = b.option(
        bool,
        "openvpn",
        "Compile the OpenVPN library.",
    ) orelse false;
    const wg_path = pathOption(b, "wg-go-lib", "CMake-built WireGuard Go library or Windows import library.", false);
    const use_wireguard = b.option(
        bool,
        "wireguard",
        "Compile the WireGuard library.",
    ) orelse (wg_path != null);
    if (!use_wireguard and wg_path != null)
        std.debug.panic("-Dwg-go-lib cannot be combined with -Dwireguard=false", .{});
    const vendors = Vendors{
        .openssl = vendorPathsOption(b, .openssl),
        .mbedtls = vendorPathsOption(b, .mbedtls),
        .openssl_config_include = pathOption(
            b,
            "openssl-config-include",
            "OpenSSL platform-specific headers search path.",
            false,
        ),
    };
    const apple_sdk_path = if (target.result.os.tag.isDarwin())
        b.option([]const u8, "apple-sdk-path", "Path to the Apple platform SDK.")
    else
        null;

    const build_options = b.addOptions();
    build_options.addOption(bool, "openvpn", use_openvpn);
    build_options.addOption(bool, "wireguard", use_wireguard);
    const winrt_path = pathOption(b, "winrt-lib", "MSVC-built portable WinRT bridge archive.", false);
    const use_winrt = b.option(bool, "winrt", "Link the CMake-built WinRT bridge (Windows MSVC only).") orelse (winrt_path != null);
    if (!use_winrt and winrt_path != null)
        std.debug.panic("-Dwinrt-lib cannot be combined with -Dwinrt=false", .{});
    if (use_winrt and (target.result.os.tag != .windows or target.result.abi != .msvc))
        std.debug.panic("WinRT requires a Windows MSVC target", .{});
    if (use_winrt and winrt_path == null)
        std.debug.panic("Build WinRT with CMake and supply -Dwinrt-lib", .{});
    const winrt_library: ?std.Build.LazyPath = if (winrt_path) |path| .{ .cwd_relative = path } else null;
    build_options.addOption(bool, "winrt", winrt_library != null);

    const config = BuildConfig{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .libc_installation = parseLibCInstallation(b, target),
        .apple_sdk_path = apple_sdk_path,
        .vendors = vendors,
        .winrt_library = winrt_library,
        .wg_go = if (wg_path) |path| .{ .cwd_relative = path } else null,
        .openvpn = use_openvpn,
        .wireguard = use_wireguard,
        .options = build_options,
    };
    const c_bindings = createCBindings(b, config);

    const module = createPartoutModule(b, config, c_bindings, "src/partout.zig", true);
    if (shared and !target.result.os.tag.isDarwin()) {
        linkVendorLibraries(module, b, config, false);
        linkWireGuard(module, config, false);
        addRuntimeOrigin(module, target);
    }

    const lib = b.addLibrary(.{
        .linkage = if (shared and !target.result.os.tag.isDarwin()) .dynamic else .static,
        .name = "partout",
        .root_module = module,
    });
    if (shared and winrt_library != null) {
        lib.forceUndefinedSymbol("pp_winrt_runtime_link");
    }
    if (install_name != null) {
        if (!shared or !target.result.os.tag.isDarwin()) {
            std.debug.panic("-Dinstall-name requires a shared Darwin target", .{});
        }
    }

    const check = b.step("check", "Check if partout compiles");
    check.dependOn(&lib.step);
    b.default_step = check;

    const test_source_module = createPartoutModule(b, config, c_bindings, "src/testing.zig", false);
    const test_module = createPartoutModule(b, config, c_bindings, "tests/all.zig", true);
    linkVendorLibraries(test_module, b, config, true);
    linkWireGuard(test_module, config, true);
    test_module.addImport("source", test_source_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    // The MSVC C++/WinRT bridge is built with /MD.
    if (winrt_library != null) unit_tests.linkage = .dynamic;
    unit_tests.step.dependOn(api_codegen_step);
    check.dependOn(&unit_tests.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&run_unit_tests.step);

    const coverage_step = b.step("coverage", "Run Zig tests under kcov");
    coverage_step.dependOn(&addCoverageRunStep(b, unit_tests).step);

    if (target.result.os.tag.isDarwin()) {
        const repacked_lib = addDarwinStaticArchiveRepackStep(b, lib.getEmittedBin(), config.wg_go);
        const output = if (shared) addAppleSharedLibrary(b, config, repacked_lib, install_name) else repacked_lib;
        b.getInstallStep().dependOn(&b.addInstallLibFile(output, if (shared) "libpartout.dylib" else "libpartout.a").step);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("src/partout.h"), "partout.h").step);
    } else {
        lib.installHeader(b.path("src/partout.h"), "partout.h");
        if (winrt_library != null) {
            lib.installHeader(b.path("cross/windows/runtime.h"), "runtime.h");
        }
        b.installArtifact(lib);
    }

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}

fn parseLibCInstallation(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ?std.zig.LibCInstallation {
    const libc_file = b.libc_file orelse return null;
    return std.zig.LibCInstallation.parse(
        b.allocator,
        b.graph.io,
        libc_file,
        &target.result,
    ) catch |err| std.debug.panic("unable to parse --libc file '{s}': {s}", .{
        libc_file,
        @errorName(err),
    });
}

fn pathOption(
    b: *std.Build,
    name: []const u8,
    description: []const u8,
    required: bool,
) ?[]const u8 {
    const raw = b.option([]const u8, name, description) orelse {
        if (required) std.debug.panic("-{s} is required by the selected build options", .{name});
        return null;
    };
    if (raw.len == 0) std.debug.panic("-{s} cannot be empty", .{name});

    const path = if (std.fs.path.isAbsolute(raw)) raw else b.pathFromRoot(raw);
    std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch
        std.debug.panic("-{s} path is missing: {s}", .{ name, path });
    return b.dupe(path);
}

fn vendorPathsOption(b: *std.Build, vendor: Vendor) VendorPaths {
    const name = vendor.optionName();
    const display_name = vendor.displayName();
    const include = pathOption(
        b,
        b.fmt("{s}-include", .{name}),
        b.fmt("{s} headers search path.", .{display_name}),
        false,
    );
    const library = pathOption(
        b,
        b.fmt("{s}-lib", .{name}),
        b.fmt("{s} library search path.", .{display_name}),
        include != null,
    );
    if (include == null and library != null) {
        std.debug.panic("-{s}-include is required with -{s}-lib", .{ name, name });
    }
    return .{ .vendor = vendor, .include = include, .library = library };
}

fn addAPICodegenStep(b: *std.Build) *std.Build.Step {
    const excluded_schemas = b.option(
        []const u8,
        "api-exclude-schemas",
        "Comma-separated OpenAPI schema names to omit from the output.",
    ) orelse default_api_excluded_schemas;
    const generator_module = b.createModule(.{
        .root_source_file = b.path("tools/openapi_codegen.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const generator = b.addExecutable(.{
        .name = "api-codegen",
        .root_module = generator_module,
    });
    const run = b.addRunArtifact(generator);
    run.addArg("scripts/openapi.yaml");
    run.addArg("src/core/api_generated.zig");
    if (excluded_schemas.len > 0) {
        run.addArg("--exclude");
        run.addArg(excluded_schemas);
    }
    run.has_side_effects = true;

    const step = b.step("gen-api", "Generate Zig models from OpenAPI");
    step.dependOn(&run.step);
    return step;
}

fn addCoverageRunStep(
    b: *std.Build,
    unit_tests: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const include_paths = b.option(
        []const u8,
        "coverage-include",
        "Comma-separated paths to include in the kcov report.",
    ) orelse b.pathFromRoot("src");
    const output_path = b.option(
        []const u8,
        "coverage-output",
        "Directory for the kcov report.",
    ) orelse b.pathFromRoot("zig-out/coverage");

    const clean = b.addSystemCommand(&.{ "rm", "-rf", output_path });
    clean.has_side_effects = true;
    clean.setCwd(b.path("."));
    clean.setName("remove previous kcov report");

    const run = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        b.fmt("--include-path={s}", .{include_paths}),
        output_path,
    });
    run.addFileArg(unit_tests.getEmittedBin());
    run.has_side_effects = true;
    run.setCwd(b.path("."));
    run.setName("run tests with kcov");
    run.step.dependOn(&clean.step);
    return run;
}

fn createPartoutModule(
    b: *std.Build,
    config: BuildConfig,
    c_bindings: CBindings,
    root_source_file: []const u8,
    add_c_sources: bool,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = config.target,
        .optimize = config.optimize,
        .strip = config.strip,
        .link_libc = true,
        .sanitize_c = .off,
    });
    configurePartoutModule(module, b, config);
    c_bindings.addImports(module);

    if (add_c_sources) {
        if (config.target.result.os.tag == .windows) {
            if (config.winrt_library) |library| {
                module.addObjectFile(library);
                module.linkSystemLibrary("windowsapp", .{});
                module.linkSystemLibrary("runtimeobject", .{});
            } else {
                addCSourceFiles(module, &.{"src/c/portable/tun_windows_dummy.c"});
            }
        }
        addCSources(module, config.openvpn, config.wireguard);
        addCryptoCSources(module, config);
    }
    return module;
}

fn createCBindings(b: *std.Build, config: BuildConfig) CBindings {
    return .{
        .portable = createCBinding(b, config, "src/c/imports/portable.h"),
        .io = createCBinding(b, config, "src/c/imports/io.h"),
        .crypto = createCBinding(b, config, "src/c/imports/crypto.h"),
        .partout = createCBinding(b, config, "src/c/imports/partout.h"),
        .openvpn = if (config.openvpn)
            createCBinding(b, config, "src/c/imports/openvpn.h")
        else
            null,
        .wireguard = if (config.wireguard)
            createCBinding(b, config, "src/c/imports/wireguard.h")
        else
            null,
    };
}

fn createCBinding(
    b: *std.Build,
    config: BuildConfig,
    root_source_file: []const u8,
) *std.Build.Module {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path(root_source_file),
        .target = config.target,
        .optimize = config.optimize,
    });
    configureCTranslation(translate_c, b, config);
    return translate_c.createModule();
}

fn configureCTranslation(
    translate_c: *std.Build.Step.TranslateC,
    b: *std.Build,
    config: BuildConfig,
) void {
    configureCHeadersAndMacros(translate_c, b, config);
}

fn configurePartoutModule(
    module: *std.Build.Module,
    b: *std.Build,
    config: BuildConfig,
) void {
    module.addOptions("build_options", config.options);
    configureCHeadersAndMacros(module, b, config);
    addAppleSDKLibraryPath(module, b, config.apple_sdk_path);
    if (config.target.result.os.tag.isDarwin()) {
        module.linkFramework("CoreFoundation", .{});
        module.linkFramework("Security", .{});
    }
    if (config.target.result.os.tag == .windows) {
        module.linkSystemLibrary("bcrypt", .{});
        module.linkSystemLibrary("ole32", .{});
        module.linkSystemLibrary("ws2_32", .{});
    }
}

fn configureCHeadersAndMacros(
    consumer: anytype,
    b: *std.Build,
    config: BuildConfig,
) void {
    consumer.addIncludePath(b.path("src"));
    consumer.addIncludePath(b.path("src/c/portable/include"));
    consumer.addIncludePath(b.path("src/c/crypto/include"));
    if (config.target.result.os.tag == .windows) {
        consumer.addIncludePath(b.path("cross/windows"));
    }
    if (config.openvpn) {
        consumer.addIncludePath(b.path("src/openvpn/c/include"));
    }
    if (config.wireguard) {
        consumer.addIncludePath(b.path("src/wireguard/c/include"));
        consumer.addIncludePath(b.path("src/wireguard/go/include"));
    }
    addVendorIncludePaths(consumer, b, config);
    addAppleSDKHeaderPaths(consumer, b, config.apple_sdk_path);
    addLibCHeaderPaths(consumer, config.libc_installation);
    if (config.vendors.openssl.enabled()) {
        addCMacro(consumer, "PARTOUT_CRYPTO_OPENSSL", "1");
    }
    if (config.vendors.mbedtls.enabled()) {
        addCMacro(consumer, "PARTOUT_CRYPTO_MBEDTLS", "1");
    }
    addCMacro(consumer, "PARTOUT_OPENVPN", if (config.openvpn) "1" else "0");
    addCMacro(consumer, "PARTOUT_WIREGUARD", if (config.wireguard) "1" else "0");
    addCMacro(
        consumer,
        "PARTOUT_HAS_WIREGUARD_BACKEND",
        if (config.wg_go != null) "1" else "0",
    );
}

fn addLibCHeaderPaths(
    consumer: anytype,
    libc_installation: ?std.zig.LibCInstallation,
) void {
    const libc = libc_installation orelse return;
    consumer.addSystemIncludePath(.{ .cwd_relative = libc.include_dir orelse unreachable });
    const sys_include_dir = libc.sys_include_dir orelse unreachable;
    if (!std.mem.eql(u8, libc.include_dir.?, sys_include_dir)) {
        consumer.addSystemIncludePath(.{ .cwd_relative = sys_include_dir });
    }
}

fn addCMacro(consumer: anytype, name: []const u8, value: []const u8) void {
    if (comptime @TypeOf(consumer) == *std.Build.Module) {
        consumer.addCMacro(name, value);
    } else if (comptime @TypeOf(consumer) == *std.Build.Step.TranslateC) {
        consumer.defineCMacro(name, value);
    } else {
        @compileError("unsupported C build consumer");
    }
}

fn addVendorIncludePaths(
    consumer: anytype,
    b: *std.Build,
    config: BuildConfig,
) void {
    for (config.vendors.all()) |paths| {
        const include_path = paths.include orelse continue;
        const framework_name = paths.vendor.frameworkName();
        if (config.target.result.os.tag.isDarwin()) {
            const framework = b.fmt("{s}/{s}.framework", .{ include_path, framework_name });
            std.Io.Dir.accessAbsolute(b.graph.io, framework, .{}) catch {
                consumer.addSystemIncludePath(.{ .cwd_relative = include_path });
                continue;
            };
            consumer.addSystemFrameworkPath(.{ .cwd_relative = include_path });
        } else {
            consumer.addSystemIncludePath(.{ .cwd_relative = include_path });
        }
    }
    for ([_]?[]const u8{
        config.vendors.openssl_config_include,
    }) |include_path| {
        consumer.addSystemIncludePath(.{ .cwd_relative = include_path orelse continue });
    }
}

fn linkVendorLibraries(
    module: *std.Build.Module,
    b: *std.Build,
    config: BuildConfig,
    add_library_rpath: bool,
) void {
    for (config.vendors.all()) |paths| {
        if (!paths.enabled()) continue;
        const library_path = paths.library orelse unreachable;
        const framework_name = paths.vendor.frameworkName();
        if (config.target.result.os.tag.isDarwin()) {
            const framework = b.fmt("{s}/{s}.framework", .{ library_path, framework_name });
            std.Io.Dir.accessAbsolute(b.graph.io, framework, .{}) catch {
                const archive = b.fmt(
                    "{s}/{s}",
                    .{ library_path, paths.vendor.appleStaticArchiveName() },
                );
                std.Io.Dir.accessAbsolute(b.graph.io, archive, .{}) catch {
                    linkSystemLibraries(module, config.target, paths, add_library_rpath);
                    continue;
                };
                module.addObjectFile(.{ .cwd_relative = archive });
                continue;
            };
            module.addSystemFrameworkPath(.{ .cwd_relative = library_path });
            module.linkFramework(framework_name, .{});
            if (add_library_rpath) {
                module.addRPath(.{ .cwd_relative = library_path });
            }
        } else {
            linkSystemLibraries(module, config.target, paths, add_library_rpath);
        }
    }
}

fn linkSystemLibraries(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    paths: VendorPaths,
    add_library_rpath: bool,
) void {
    const library_path = paths.library orelse unreachable;
    module.addLibraryPath(.{ .cwd_relative = library_path });
    if (add_library_rpath) {
        module.addRPath(.{ .cwd_relative = library_path });
    }
    linkSystemLibraryNames(module, target, paths.vendor);
}

fn linkSystemLibraryNames(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    vendor: Vendor,
) void {
    const options: std.Build.Module.LinkSystemLibraryOptions = .{
        .use_pkg_config = .no,
    };
    switch (vendor) {
        .openssl => if (target.result.os.tag == .windows) {
            module.linkSystemLibrary("libssl", options);
            module.linkSystemLibrary("libcrypto", options);
        } else {
            module.linkSystemLibrary("ssl", options);
            module.linkSystemLibrary("crypto", options);
        },
        .mbedtls => {
            module.linkSystemLibrary("mbedtls", options);
            module.linkSystemLibrary("mbedx509", options);
            module.linkSystemLibrary("mbedcrypto", options);
        },
    }
}

fn linkWireGuard(module: *std.Build.Module, config: BuildConfig, testing: bool) void {
    const wg = config.wg_go orelse return;
    module.addObjectFile(wg);
    if (testing and config.target.result.os.tag == .linux) module.addRPath(wg.dirname());
}

fn addRuntimeOrigin(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.os.tag.isDarwin()) {
        module.addRPath(.{ .cwd_relative = "@loader_path" });
    } else if (target.result.os.tag != .windows) {
        module.addRPath(.{ .cwd_relative = "$ORIGIN" });
    }
}

// Apple dylibs use the native linker for export control and framework metadata.
// Keep this Zig/C link step in the Zig build, including for XCFramework slices.
fn addAppleSharedLibrary(b: *std.Build, config: BuildConfig, archive: std.Build.LazyPath, install_name: ?[]const u8) std.Build.LazyPath {
    const t = config.target.result;
    const arch = if (t.cpu.arch == .aarch64) "arm64" else @tagName(t.cpu.arch);
    const triple = b.fmt("{s}-apple-{s}{f}{s}", .{ arch, @tagName(t.os.tag), t.os.version_range.semver.min, if (t.abi == .simulator) "-simulator" else "" });
    const run = b.addSystemCommand(&.{ "xcrun", "clang", "-target", triple, "-dynamiclib", "-Wl,-compatibility_version,1.0.0", "-Wl,-current_version,1.0.0", "-Wl,-dead_strip", "-Wl,-rpath,@loader_path", "-Xlinker", "-install_name", "-Xlinker", install_name orelse "@rpath/libpartout.dylib" });
    if (config.apple_sdk_path) |sdk| run.addArgs(&.{ "-isysroot", sdk });
    run.addArgs(&.{ "-Xlinker", "-exported_symbols_list", "-Xlinker" });
    run.addFileArg(b.path("src/partout.exports"));
    run.addArgs(&.{ "-Xlinker", "-force_load", "-Xlinker" });
    run.addFileArg(archive);
    for (config.vendors.all()) |paths| {
        if (!paths.enabled()) continue;
        const directory = paths.library.?;
        const framework = b.fmt("{s}/{s}.framework", .{ directory, paths.vendor.frameworkName() });
        std.Io.Dir.accessAbsolute(b.graph.io, framework, .{}) catch {
            const vendor_archive = b.fmt("{s}/{s}", .{ directory, paths.vendor.appleStaticArchiveName() });
            std.Io.Dir.accessAbsolute(b.graph.io, vendor_archive, .{}) catch {
                run.addArgs(&.{ "-L", directory });
                switch (paths.vendor) {
                    .openssl => run.addArgs(&.{ "-lssl", "-lcrypto" }),
                    .mbedtls => run.addArgs(&.{ "-lmbedtls", "-lmbedx509", "-lmbedcrypto" }),
                }
                // The system linker resolves these files; recheck them each build.
                run.has_side_effects = true;
                continue;
            };
            run.addFileArg(.{ .cwd_relative = vendor_archive });
            continue;
        };
        run.addArgs(&.{ "-F", directory, "-framework", paths.vendor.frameworkName() });
        run.has_side_effects = true;
    }
    run.addArgs(&.{ "-framework", "CoreFoundation", "-framework", "Security", "-o" });
    const output = run.addOutputFileArg("libpartout.dylib");
    run.setName("link Apple shared library");
    return output;
}

fn addDarwinStaticArchiveRepackStep(
    b: *std.Build,
    source: std.Build.LazyPath,
    wg_go: ?std.Build.LazyPath,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\archive="$1"
        \\out="$2"
        \\work="${out}.objects"
        \\archive_dir="$(dirname "$archive")"
        \\archive_base="$(basename "$archive")"
        \\archive="$(cd "$archive_dir" && pwd)/$archive_base"
        \\rm -rf "$work" "$out"
        \\mkdir -p "$work"
        \\wg=
        \\if [ -n "${3:-}" ]; then wg="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"; fi
        \\cd "$work"
        \\ar -x "$archive"
        \\chmod u+r ./*.o
        \\if [ -n "${3:-}" ]; then
        \\    libtool -static -no_warning_for_no_symbols -o "$out" ./*.o "$wg"
        \\else
        \\    libtool -static -no_warning_for_no_symbols -o "$out" ./*.o
        \\fi
        \\rm -rf "$work"
        ,
        "repack-darwin-static-archive",
    });
    run.addFileArg(source);
    const output = run.addOutputFileArg("libpartout.a");
    if (wg_go) |wg| run.addFileArg(wg);
    run.setName("repack Darwin static archive");
    return output;
}

fn addAppleSDKHeaderPaths(
    consumer: anytype,
    b: *std.Build,
    sdk_path: ?[]const u8,
) void {
    const sdk = sdk_path orelse return;
    consumer.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
    consumer.addSystemFrameworkPath(.{
        .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}),
    });
}

fn addAppleSDKLibraryPath(
    module: *std.Build.Module,
    b: *std.Build,
    sdk_path: ?[]const u8,
) void {
    const sdk = sdk_path orelse return;
    module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
}

fn addCSources(module: *std.Build.Module, use_openvpn: bool, use_wireguard: bool) void {
    addCSourceFiles(module, &.{
        "src/partout.c",
        "src/partout_jni.c",
    });
    addCSourceFiles(module, &.{
        "src/c/portable/common.c",
        "src/c/portable/dns.c",
        "src/c/portable/lib.c",
        "src/c/portable/mux.c",
        "src/c/portable/network.c",
        "src/c/portable/prng.c",
        "src/c/portable/socket.c",
        "src/c/portable/tun_android.c",
        "src/c/portable/tun_darwin.c",
        "src/c/portable/tun_linux.c",
        "src/c/portable/zd.c",
    });

    if (use_openvpn) {
        addCSourceFiles(module, &.{
            "src/openvpn/c/control.c",
            "src/openvpn/c/dp_framing.c",
            "src/openvpn/c/dp_mode.c",
            "src/openvpn/c/dp_mode_ad.c",
            "src/openvpn/c/dp_mode_hmac.c",
            "src/openvpn/c/mss_fix.c",
            "src/openvpn/c/pkt_proc.c",
            "src/openvpn/c/test/openvpn_crypto_mock.c",
        });
    }

    if (use_wireguard) {
        addCSourceFiles(module, &.{
            "src/wireguard/c/backend.c",
            "src/wireguard/c/key.c",
            "src/wireguard/c/x25519.c",
        });
    }
}

fn addCryptoCSources(
    module: *std.Build.Module,
    config: BuildConfig,
) void {
    addCSourceFiles(module, &.{
        "src/c/crypto/tls_options.c",
        "src/c/crypto/crypto_mock.c",
    });

    if (config.vendors.openssl.enabled()) {
        addCSourceFiles(module, &.{"src/c/crypto/crypto_openssl.c"});
    }

    if (config.vendors.mbedtls.enabled()) {
        addCSourceFiles(module, &.{"src/c/crypto/crypto_mbedtls.c"});
        addNativeCryptoCSources(module, config.target);
    }
}

fn addCSourceFiles(module: *std.Build.Module, files: []const []const u8) void {
    module.addCSourceFiles(.{ .files = files, .flags = c_flags });
}

fn addNativeCryptoCSources(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    switch (target.result.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => addCSourceFiles(module, &.{"src/c/crypto/crypto_darwin.c"}),
        .linux => addCSourceFiles(module, &.{"src/c/crypto/crypto_linux.c"}),
        .windows => addCSourceFiles(module, &.{"src/c/crypto/crypto_windows.c"}),
        else => {},
    }
}
