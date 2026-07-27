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
};

const CryptoLibraries = struct {
    openssl: bool = false,
    mbedtls: bool = false,
};

const VendorIncludePaths = struct {
    openssl: ?[]const u8,
    mbedtls: ?[]const u8,
    wg_go: ?[]const u8,
    wintun: ?[]const u8,
};

const VendorLibraryPaths = struct {
    openssl: ?[]const u8,
    mbedtls: ?[]const u8,
    wg_go: ?[]const u8,
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
    const api_codegen_step = addAPICodegenStep(b);
    const embed_c = b.option(
        bool,
        "embed-c",
        "Embed the C implementations instead of resolving them at the final link.",
    ) orelse false;
    const shared = b.option(
        bool,
        "shared",
        "Build Partout as a shared library.",
    ) orelse false;
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
    const vendor_includes = VendorIncludePaths{
        .openssl = pathOption(b, "openssl-include", "OpenSSL headers search path.", false),
        .mbedtls = pathOption(b, "mbedtls-include", "MbedTLS headers search path.", false),
        .wg_go = pathOption(b, "wg-go-include", "wg-go headers search path.", false),
        .wintun = pathOption(b, "wintun-include", "Wintun headers search path.", false),
    };
    const crypto_libraries = CryptoLibraries{
        .openssl = vendor_includes.openssl != null,
        .mbedtls = vendor_includes.mbedtls != null,
    };
    const vendor_libraries = VendorLibraryPaths{
        .openssl = pathOption(
            b,
            "openssl-lib",
            "OpenSSL library search path.",
            crypto_libraries.openssl,
        ),
        .mbedtls = pathOption(
            b,
            "mbedtls-lib",
            "MbedTLS library search path.",
            crypto_libraries.mbedtls,
        ),
        .wg_go = pathOption(
            b,
            "wg-go-lib",
            "wg-go library search path.",
            vendor_includes.wg_go != null,
        ),
    };
    validatePathPair("openssl", vendor_includes.openssl, vendor_libraries.openssl);
    validatePathPair("mbedtls", vendor_includes.mbedtls, vendor_libraries.mbedtls);
    validatePathPair("wg-go", vendor_includes.wg_go, vendor_libraries.wg_go);
    const has_wireguard_backend =
        vendor_includes.wg_go != null and vendor_libraries.wg_go != null;
    const apple_sdk_path = if (target.result.os.tag.isDarwin())
        b.option([]const u8, "apple-sdk-path", "Path to the Apple platform SDK.")
    else
        null;

    const build_options = b.addOptions();
    build_options.addOption(bool, "embed_c", embed_c);
    build_options.addOption(bool, "openvpn", use_openvpn);
    build_options.addOption(bool, "wireguard", use_wireguard);

    const module = b.createModule(.{
        .root_source_file = b.path("src/partout.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    configurePartoutModule(
        module,
        b,
        target,
        apple_sdk_path,
        crypto_libraries,
        vendor_includes,
        has_wireguard_backend,
        embed_c,
        use_openvpn,
        use_wireguard,
        build_options,
    );
    if (shared) {
        linkVendorLibraries(
            module,
            b,
            target,
            crypto_libraries,
            use_wireguard and has_wireguard_backend,
            vendor_libraries,
            false,
        );
        addRuntimeOrigin(module, target);
    }

    const lib = b.addLibrary(.{
        .linkage = if (shared) .dynamic else .static,
        .name = "partout",
        .root_module = module,
    });

    const check = b.step("check", "Check if partout compiles");
    check.dependOn(&lib.step);
    b.default_step = check;

    const test_source_module = b.createModule(.{
        .root_source_file = b.path("src/testing.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    configurePartoutModuleSettings(
        test_source_module,
        b,
        target,
        apple_sdk_path,
        crypto_libraries,
        vendor_includes,
        has_wireguard_backend,
        use_openvpn,
        use_wireguard,
        build_options,
    );

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    configurePartoutModule(
        test_module,
        b,
        target,
        apple_sdk_path,
        crypto_libraries,
        vendor_includes,
        has_wireguard_backend,
        embed_c,
        use_openvpn,
        use_wireguard,
        build_options,
    );
    linkVendorLibraries(
        test_module,
        b,
        target,
        crypto_libraries,
        use_wireguard and has_wireguard_backend,
        vendor_libraries,
        true,
    );
    test_module.addImport("source", test_source_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    unit_tests.step.dependOn(api_codegen_step);
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

fn validatePathPair(
    name: []const u8,
    include_path: ?[]const u8,
    library_path: ?[]const u8,
) void {
    if (include_path == null and library_path != null) {
        std.debug.panic("-{s}-include is required with -{s}-lib", .{ name, name });
    }
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
    run.addArg("../scripts/openapi.yaml");
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

fn configurePartoutModule(
    module: *std.Build.Module,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    apple_sdk_path: ?[]const u8,
    crypto_libraries: CryptoLibraries,
    vendor_includes: VendorIncludePaths,
    has_wireguard_backend: bool,
    embed_c: bool,
    use_openvpn: bool,
    use_wireguard: bool,
    build_options: *std.Build.Step.Options,
) void {
    configurePartoutModuleSettings(
        module,
        b,
        target,
        apple_sdk_path,
        crypto_libraries,
        vendor_includes,
        has_wireguard_backend,
        use_openvpn,
        use_wireguard,
        build_options,
    );

    if (embed_c) {
        addCSources(module, use_openvpn, use_wireguard);
        addCryptoCSources(module, target, crypto_libraries);
    }
}

fn configurePartoutModuleSettings(
    module: *std.Build.Module,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    apple_sdk_path: ?[]const u8,
    crypto_libraries: CryptoLibraries,
    vendor_includes: VendorIncludePaths,
    has_wireguard_backend: bool,
    use_openvpn: bool,
    use_wireguard: bool,
    build_options: *std.Build.Step.Options,
) void {
    module.addOptions("build_options", build_options);
    module.addIncludePath(b.path("src"));
    module.addIncludePath(b.path("src/c/portable/include"));
    module.addIncludePath(b.path("src/c/crypto/include"));
    if (use_openvpn) {
        module.addIncludePath(b.path("src/openvpn/c/include"));
    }
    if (use_wireguard) {
        module.addIncludePath(b.path("src/wireguard/c/include"));
    }
    addVendorIncludePaths(module, b, target, vendor_includes);
    addAppleSDKPaths(module, b, apple_sdk_path);
    if (crypto_libraries.openssl) {
        module.addCMacro("PARTOUT_CRYPTO_OPENSSL", "1");
    }
    if (crypto_libraries.mbedtls) {
        module.addCMacro("PARTOUT_CRYPTO_MBEDTLS", "1");
    }
    module.addCMacro("PARTOUT_OPENVPN", if (use_openvpn) "1" else "0");
    module.addCMacro("PARTOUT_WIREGUARD", if (use_wireguard) "1" else "0");
    module.addCMacro(
        "PARTOUT_HAS_WIREGUARD_BACKEND",
        if (has_wireguard_backend) "1" else "0",
    );
    if (target.result.os.tag.isDarwin()) {
        module.linkFramework("Security", .{});
    }
    if (target.result.os.tag == .windows) {
        module.linkSystemLibrary("bcrypt", .{});
        module.linkSystemLibrary("ole32", .{});
        module.linkSystemLibrary("ws2_32", .{});
    }
}

fn addVendorIncludePaths(
    module: *std.Build.Module,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    paths: VendorIncludePaths,
) void {
    const Entry = struct {
        path: ?[]const u8,
        framework_name: ?[]const u8,
    };
    const entries = [_]Entry{
        .{ .path = paths.openssl, .framework_name = "openssl" },
        .{ .path = paths.mbedtls, .framework_name = "mbedtls" },
        .{ .path = paths.wg_go, .framework_name = "wg_go" },
        .{ .path = paths.wintun, .framework_name = null },
    };
    for (entries) |entry| {
        const path = entry.path orelse continue;
        const fwname = entry.framework_name orelse {
            module.addSystemIncludePath(.{ .cwd_relative = path });
            continue;
        };
        if (target.result.os.tag.isDarwin()) {
            const framework = b.fmt("{s}/{s}.framework", .{ path, fwname });
            std.Io.Dir.accessAbsolute(b.graph.io, framework, .{}) catch {
                module.addSystemIncludePath(.{ .cwd_relative = path });
                continue;
            };
            module.addSystemFrameworkPath(.{ .cwd_relative = path });
        } else {
            module.addSystemIncludePath(.{ .cwd_relative = path });
        }
    }
}

fn linkVendorLibraries(
    module: *std.Build.Module,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    libraries: CryptoLibraries,
    has_wireguard_backend: bool,
    library_paths: VendorLibraryPaths,
    add_library_rpath: bool,
) void {
    const Entry = struct {
        enabled: bool,
        library_path: ?[]const u8,
        name: []const u8,
    };
    const entries = [_]Entry{
        .{
            .enabled = libraries.openssl,
            .library_path = library_paths.openssl,
            .name = "openssl",
        },
        .{
            .enabled = libraries.mbedtls,
            .library_path = library_paths.mbedtls,
            .name = "mbedtls",
        },
        .{
            .enabled = has_wireguard_backend,
            .library_path = library_paths.wg_go,
            .name = "wg_go",
        },
    };
    for (entries) |entry| {
        if (!entry.enabled) continue;
        const library_path = entry.library_path orelse unreachable;
        if (target.result.os.tag.isDarwin()) {
            const framework = b.fmt("{s}/{s}.framework", .{ library_path, entry.name });
            std.Io.Dir.accessAbsolute(b.graph.io, framework, .{}) catch {
                linkSystemLibraries(module, target, library_path, entry.name, add_library_rpath);
                continue;
            };
            module.addSystemFrameworkPath(.{ .cwd_relative = library_path });
            module.linkFramework(entry.name, .{});
            if (add_library_rpath) {
                module.addRPath(.{ .cwd_relative = library_path });
            }
        } else {
            linkSystemLibraries(module, target, library_path, entry.name, add_library_rpath);
        }
    }
}

fn linkSystemLibraries(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    library_path: []const u8,
    name: []const u8,
    add_library_rpath: bool,
) void {
    module.addLibraryPath(.{ .cwd_relative = library_path });
    if (add_library_rpath) {
        module.addRPath(.{ .cwd_relative = library_path });
    }
    linkSystemLibraryNames(module, target, name);
}

fn linkSystemLibraryNames(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    name: []const u8,
) void {
    var options: std.Build.Module.LinkSystemLibraryOptions = .{
        .use_pkg_config = .no,
    };
    if (std.mem.eql(u8, name, "openssl")) {
        if (target.result.os.tag == .windows) {
            module.linkSystemLibrary("libssl", options);
            module.linkSystemLibrary("libcrypto", options);
        } else {
            module.linkSystemLibrary("ssl", options);
            module.linkSystemLibrary("crypto", options);
        }
    } else if (std.mem.eql(u8, name, "mbedtls")) {
        module.linkSystemLibrary("mbedtls", options);
        module.linkSystemLibrary("mbedx509", options);
        module.linkSystemLibrary("mbedcrypto", options);
    } else if (std.mem.eql(u8, name, "wg_go")) {
        // Disambiguate import .lib from .dll
        if (target.result.os.tag == .windows) {
            options.preferred_link_mode = .static;
        }
        module.linkSystemLibrary("wg-go", options);
    } else {
        unreachable;
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
    module.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
}

fn addCSources(module: *std.Build.Module, use_openvpn: bool, use_wireguard: bool) void {
    module.addCSourceFiles(.{ .files = &.{
        "src/partout.c",
    } });
    module.addCSourceFiles(.{
        .files = &.{
            "src/c/portable/common.c",
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
        },
        .flags = c_flags,
    });

    if (use_openvpn) {
        module.addCSourceFiles(.{
            .files = &.{
                "src/openvpn/c/control.c",
                "src/openvpn/c/dp_framing.c",
                "src/openvpn/c/dp_mode.c",
                "src/openvpn/c/dp_mode_ad.c",
                "src/openvpn/c/dp_mode_hmac.c",
                "src/openvpn/c/mss_fix.c",
                "src/openvpn/c/pkt_proc.c",
                "src/openvpn/c/test/openvpn_crypto_mock.c",
            },
            .flags = c_flags,
        });
    }

    if (use_wireguard) {
        module.addCSourceFiles(.{
            .files = &.{
                "src/wireguard/c/backend.c",
                "src/wireguard/c/key.c",
                "src/wireguard/c/x25519.c",
            },
            .flags = c_flags,
        });
    }
}

fn addCryptoCSources(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    crypto_libraries: CryptoLibraries,
) void {
    module.addCSourceFiles(.{
        .files = &.{
            "src/c/crypto/tls_options.c",
            "src/c/crypto/crypto_mock.c",
        },
        .flags = c_flags,
    });

    if (crypto_libraries.openssl) {
        module.addCSourceFiles(.{
            .files = &.{
                "src/c/crypto/crypto_openssl.c",
            },
            .flags = c_flags,
        });
    }

    if (crypto_libraries.mbedtls) {
        module.addCSourceFiles(.{
            .files = &.{
                "src/c/crypto/crypto_mbedtls.c",
            },
            .flags = c_flags,
        });
        addNativeCryptoCSources(module, target);
    }
}

fn addNativeCryptoCSources(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    switch (target.result.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => module.addCSourceFiles(.{
            .files = &.{
                "src/c/crypto/crypto_darwin.c",
            },
            .flags = c_flags,
        }),
        .linux => module.addCSourceFiles(.{
            .files = &.{
                "src/c/crypto/crypto_linux.c",
            },
            .flags = c_flags,
        }),
        .windows => module.addCSourceFiles(.{
            .files = &.{
                "src/c/crypto/crypto_windows.c",
            },
            .flags = c_flags,
        }),
        else => {},
    }
}
