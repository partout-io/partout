// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

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
    wg_go,

    fn optionName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "openssl",
            .mbedtls => "mbedtls",
            .wg_go => "wg-go",
        };
    }

    fn displayName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "OpenSSL",
            .mbedtls => "MbedTLS",
            .wg_go => "wg-go",
        };
    }

    fn frameworkName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "openssl",
            .mbedtls => "mbedtls",
            .wg_go => "wg_go",
        };
    }

    fn appleStaticArchiveName(vendor: Vendor) []const u8 {
        return switch (vendor) {
            .openssl => "libopenssl.a",
            .mbedtls => "libmbedtls.a",
            .wg_go => "libwg-go.a",
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
    wg_go: VendorPaths,
    openssl_config_include: ?[]const u8,
    wintun_include: ?[]const u8,

    fn all(vendors: Vendors) [3]VendorPaths {
        return .{ vendors.openssl, vendors.mbedtls, vendors.wg_go };
    }

    fn hasWireGuardBackend(vendors: Vendors) bool {
        return vendors.wg_go.enabled();
    }
};

const BuildConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    apple_sdk_path: ?[]const u8,
    vendors: Vendors,
    embed_c: bool,
    openvpn: bool,
    wireguard: bool,
    options: *std.Build.Step.Options,
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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });
    const strip = b.option(bool, "strip", "Omit debug information from emitted binaries.");
    const api_codegen_step = addAPICodegenStep(b);
    const legacy_build = b.option(
        bool,
        "legacy-build",
        "Build for the legacy Swift integration that provides C implementations.",
    ) orelse false;
    const embed_c = !legacy_build;
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
    const use_wireguard = b.option(
        bool,
        "wireguard",
        "Compile the WireGuard library.",
    ) orelse false;
    const vendors = Vendors{
        .openssl = vendorPathsOption(b, .openssl),
        .mbedtls = vendorPathsOption(b, .mbedtls),
        .wg_go = vendorPathsOption(b, .wg_go),
        .openssl_config_include = pathOption(
            b,
            "openssl-config-include",
            "OpenSSL platform-specific headers search path.",
            false,
        ),
        .wintun_include = pathOption(b, "wintun-include", "Wintun headers search path.", false),
    };
    const apple_sdk_path = if (target.result.os.tag.isDarwin())
        b.option([]const u8, "apple-sdk-path", "Path to the Apple platform SDK.")
    else
        null;

    const build_options = b.addOptions();
    build_options.addOption(bool, "legacy_build", legacy_build);
    build_options.addOption(bool, "openvpn", use_openvpn);
    build_options.addOption(bool, "wireguard", use_wireguard);

    const config = BuildConfig{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .apple_sdk_path = apple_sdk_path,
        .vendors = vendors,
        .embed_c = embed_c,
        .openvpn = use_openvpn,
        .wireguard = use_wireguard,
        .options = build_options,
    };

    const module = createPartoutModule(b, config, "src/partout.zig", true);
    if (shared) {
        linkVendorLibraries(module, b, config, false);
        addRuntimeOrigin(module, target);
    }

    const lib = b.addLibrary(.{
        .linkage = if (shared) .dynamic else .static,
        .name = "partout",
        .root_module = module,
    });
    if (install_name) |value| {
        if (!shared or !target.result.os.tag.isDarwin()) {
            std.debug.panic("-Dinstall-name requires a shared Darwin target", .{});
        }
        lib.install_name = value;
    }

    const check = b.step("check", "Check if partout compiles");
    check.dependOn(&lib.step);
    b.default_step = check;

    const test_source_module = createPartoutModule(b, config, "src/testing.zig", false);
    const test_module = createPartoutModule(b, config, "tests/all.zig", true);
    linkVendorLibraries(test_module, b, config, true);
    test_module.addImport("source", test_source_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    unit_tests.step.dependOn(api_codegen_step);
    check.dependOn(&unit_tests.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&run_unit_tests.step);

    const coverage_step = b.step("coverage", "Run Zig tests under kcov");
    coverage_step.dependOn(&addCoverageRunStep(b, unit_tests).step);

    if (!shared and target.result.os.tag.isDarwin()) {
        const repacked_lib = addDarwinStaticArchiveRepackStep(b, lib.getEmittedBin());
        b.getInstallStep().dependOn(&b.addInstallLibFile(repacked_lib, "libpartout.a").step);
        b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("src/partout.h"), "partout.h").step);
    } else {
        lib.installHeader(b.path("src/partout.h"), "partout.h");
        b.installArtifact(lib);
    }
    if (target.result.os.tag == .windows) {
        if (vendors.wintun_include) |include_path| {
            const dll = b.fmt("{s}/wintun.dll", .{include_path});
            b.getInstallStep().dependOn(&b.addInstallBinFile(
                .{ .cwd_relative = dll },
                "wintun.dll",
            ).step);
        }
    }

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
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

    if (add_c_sources and config.embed_c) {
        addCSources(module, config.openvpn, config.wireguard);
        addCryptoCSources(module, config);
    }
    return module;
}

fn configurePartoutModule(
    module: *std.Build.Module,
    b: *std.Build,
    config: BuildConfig,
) void {
    module.addOptions("build_options", config.options);
    module.addIncludePath(b.path("src"));
    module.addIncludePath(b.path("src/c/portable/include"));
    module.addIncludePath(b.path("src/c/crypto/include"));
    if (config.openvpn) {
        module.addIncludePath(b.path("src/openvpn/c/include"));
    }
    if (config.wireguard) {
        module.addIncludePath(b.path("src/wireguard/c/include"));
    }
    addVendorIncludePaths(module, b, config);
    addAppleSDKPaths(module, b, config.apple_sdk_path);
    if (config.vendors.openssl.enabled()) {
        module.addCMacro("PARTOUT_CRYPTO_OPENSSL", "1");
    }
    if (config.vendors.mbedtls.enabled()) {
        module.addCMacro("PARTOUT_CRYPTO_MBEDTLS", "1");
    }
    module.addCMacro("PARTOUT_OPENVPN", if (config.openvpn) "1" else "0");
    module.addCMacro("PARTOUT_WIREGUARD", if (config.wireguard) "1" else "0");
    module.addCMacro(
        "PARTOUT_HAS_WIREGUARD_BACKEND",
        if (config.vendors.hasWireGuardBackend()) "1" else "0",
    );
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

fn addVendorIncludePaths(
    module: *std.Build.Module,
    b: *std.Build,
    config: BuildConfig,
) void {
    for (config.vendors.all()) |paths| {
        const include_path = paths.include orelse continue;
        const framework_name = paths.vendor.frameworkName();
        if (config.target.result.os.tag.isDarwin()) {
            const framework = b.fmt("{s}/{s}.framework", .{ include_path, framework_name });
            std.Io.Dir.accessAbsolute(b.graph.io, framework, .{}) catch {
                module.addSystemIncludePath(.{ .cwd_relative = include_path });
                continue;
            };
            module.addSystemFrameworkPath(.{ .cwd_relative = include_path });
        } else {
            module.addSystemIncludePath(.{ .cwd_relative = include_path });
        }
    }
    for ([_]?[]const u8{
        config.vendors.openssl_config_include,
        config.vendors.wintun_include,
    }) |include_path| {
        module.addSystemIncludePath(.{ .cwd_relative = include_path orelse continue });
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
        if (paths.vendor == .wg_go and !config.wireguard) continue;
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
    var options: std.Build.Module.LinkSystemLibraryOptions = .{
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
        .wg_go => {
            // Disambiguate import .lib from .dll.
            if (target.result.os.tag == .windows) {
                options.preferred_link_mode = .static;
            }
            module.linkSystemLibrary("wg-go", options);
        },
    }
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

fn addDarwinStaticArchiveRepackStep(
    b: *std.Build,
    source: std.Build.LazyPath,
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
        \\cd "$work"
        \\ar -x "$archive"
        \\chmod u+r ./*.o
        \\libtool -static -no_warning_for_no_symbols -o "$out" ./*.o
        \\rm -rf "$work"
        ,
        "repack-darwin-static-archive",
    });
    run.addFileArg(source);
    const output = run.addOutputFileArg("libpartout.a");
    run.setName("repack Darwin static archive");
    return output;
}

fn addAppleSDKPaths(
    module: *std.Build.Module,
    b: *std.Build,
    sdk_path: ?[]const u8,
) void {
    const sdk = sdk_path orelse return;
    module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
    module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
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
        "src/c/portable/tun_windows.c",
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
