// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("source").core_api;
const registry_mod = @import("source").core_registry;

const ImportError = registry_mod.ImportError;
const ImportContext = registry_mod.ImportContext;
const ModuleImplementation = registry_mod.ModuleImplementation;
const Registry = registry_mod.Registry;
const SerializeError = registry_mod.SerializeError;

test "registry keeps the last implementation for each module type" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        module_type: api.ModuleType,

        fn moduleType(ptr: ?*anyopaque) api.ModuleType {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.module_type;
        }

        fn implementation(self: *@This()) ModuleImplementation {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        const vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
        };
    };

    var first = Mock{ .module_type = .OpenVPN };
    var second = Mock{ .module_type = .WireGuard };
    var replacement = Mock{ .module_type = .OpenVPN };
    const implementations = [_]ModuleImplementation{
        first.implementation(),
        second.implementation(),
        replacement.implementation(),
    };

    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), registry.all_implementations.len);
    try std.testing.expect(registry.implementation(.DNS) == null);
    try std.testing.expectEqual(api.ModuleType.OpenVPN, registry.implementation(.OpenVPN).?.moduleType());
    try std.testing.expectEqual(api.ModuleType.WireGuard, registry.implementation(.WireGuard).?.moduleType());
}

test "registry imports with the first matching callback" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        module_type: api.ModuleType,
        imported_module: ?[]const u8 = null,
        last_contents: ?[]const u8 = null,

        fn moduleType(ptr: ?*anyopaque) api.ModuleType {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.module_type;
        }

        fn importModule(
            ptr: ?*anyopaque,
            module_allocator: std.mem.Allocator,
            contents: []const u8,
            _: ?ImportContext,
        ) ImportError!api.TaggedModule {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (self.imported_module) |module_json| {
                self.last_contents = contents;
                return api.parseModule(module_allocator, module_json) catch |err| {
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.Parsing,
                    };
                };
            }
            return error.UnknownImportedModule;
        }

        fn implementation(self: *@This()) ModuleImplementation {
            return .{
                .ptr = self,
                .vtable = &implementation_vtable,
            };
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
            .import_module = importModule,
        };
    };

    var skipped = Mock{ .module_type = .OpenVPN };
    var accepted = Mock{
        .module_type = .WireGuard,
        .imported_module =
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","addresses":[]},"peers":[]}}}
        ,
    };
    const implementations = [_]ModuleImplementation{
        skipped.implementation(),
        accepted.implementation(),
    };

    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    var module = try registry.importModule(allocator, "contents", null);
    defer module.deinit(allocator);

    try std.testing.expectEqual(api.ModuleType.WireGuard, api.moduleType(&module));
    try std.testing.expectEqualStrings("contents", accepted.last_contents.?);
}

test "registry passes generic import context to probed implementations" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        module_type: api.ModuleType,
        imported_module: ?[]const u8 = null,
        saw_context: bool = false,
        saw_module_type: ?api.ModuleType = null,
        saw_ptr: bool = false,

        fn moduleType(ptr: ?*anyopaque) api.ModuleType {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.module_type;
        }

        fn importModule(
            ptr: ?*anyopaque,
            module_allocator: std.mem.Allocator,
            _: []const u8,
            context: ?ImportContext,
        ) ImportError!api.TaggedModule {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.saw_context = context != null;
            if (context) |import_context| {
                self.saw_module_type = import_context.module_type;
                self.saw_ptr = import_context.ptr != null;
            }
            if (self.imported_module) |module_json| {
                return api.parseModule(module_allocator, module_json) catch |err| {
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.Parsing,
                    };
                };
            }
            return error.UnknownImportedModule;
        }

        fn implementation(self: *@This()) ModuleImplementation {
            return .{
                .ptr = self,
                .vtable = &implementation_vtable,
            };
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
            .import_module = importModule,
        };
    };

    var skipped = Mock{ .module_type = .OpenVPN };
    var accepted = Mock{
        .module_type = .WireGuard,
        .imported_module =
        \\{"type":"WireGuard","value":{"id":"33333333-3333-4333-8333-333333333333","configuration":{"interface":{"privateKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","addresses":[]},"peers":[]}}}
        ,
    };
    const implementations = [_]ModuleImplementation{
        skipped.implementation(),
        accepted.implementation(),
    };

    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    var info: api.ParseErrorInfo = .{};
    defer info.deinit(allocator);
    var raw_context: u8 = 0;
    const import_context = ImportContext.init(&info, null, @ptrCast(&raw_context));
    try std.testing.expect(import_context.module_type == null);

    var module = try registry.importModule(
        allocator,
        "contents",
        import_context,
    );
    defer module.deinit(allocator);

    try std.testing.expect(import_context.module_type == null);
    try std.testing.expect(skipped.saw_context);
    try std.testing.expectEqual(api.ModuleType.OpenVPN, skipped.saw_module_type.?);
    try std.testing.expect(skipped.saw_ptr);
    try std.testing.expect(accepted.saw_context);
    try std.testing.expectEqual(api.ModuleType.WireGuard, accepted.saw_module_type.?);
    try std.testing.expect(accepted.saw_ptr);
}

test "registry reports missing module serializers" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        fn moduleType(_: ?*anyopaque) api.ModuleType {
            return .DNS;
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
        };
    };

    const implementations = [_]ModuleImplementation{.{
        .vtable = &Mock.implementation_vtable,
    }};
    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    var module = try api.parseModule(allocator,
        \\{"type":"DNS","value":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
    );
    defer module.deinit(allocator);

    try std.testing.expectError(
        error.MissingModuleSerializer,
        registry.serializeModule(allocator, module, null),
    );
}

test "registry serializes modules through registered serializers" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        fn moduleType(_: ?*anyopaque) api.ModuleType {
            return .DNS;
        }

        fn serializeModule(
            _: ?*anyopaque,
            module_allocator: std.mem.Allocator,
            module: api.TaggedModule,
            _: ?*anyopaque,
        ) SerializeError![]u8 {
            if (api.moduleType(&module) != .DNS) return error.UnexpectedModuleType;
            return module_allocator.dupe(u8, "serialized dns");
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
            .serialize_module = serializeModule,
        };
    };

    const implementations = [_]ModuleImplementation{.{
        .vtable = &Mock.implementation_vtable,
    }};
    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    var module = try api.parseModule(allocator,
        \\{"type":"DNS","value":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
    );
    defer module.deinit(allocator);

    const serialized = try registry.serializeModule(allocator, module, null);
    defer allocator.free(serialized);

    try std.testing.expectEqualStrings("serialized dns", serialized);
}

test "registry preserves the first importer error" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        module_type: api.ModuleType,
        err: ImportError,

        fn moduleType(ptr: ?*anyopaque) api.ModuleType {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.module_type;
        }

        fn importModule(
            ptr: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
            _: ?ImportContext,
        ) ImportError!api.TaggedModule {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.err;
        }

        fn implementation(self: *@This()) ModuleImplementation {
            return .{
                .ptr = self,
                .vtable = &implementation_vtable,
            };
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
            .import_module = importModule,
        };
    };

    var ignored = Mock{ .module_type = .OpenVPN, .err = error.UnknownImportedModule };
    var failed = Mock{ .module_type = .WireGuard, .err = error.Parsing };
    const implementations = [_]ModuleImplementation{
        ignored.implementation(),
        failed.implementation(),
    };

    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    try std.testing.expectError(error.Parsing, registry.importModule(allocator, "contents", null));
}

test "registry preserves recognized type from first concrete importer error" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        module_type: api.ModuleType,
        err: ImportError,

        fn moduleType(ptr: ?*anyopaque) api.ModuleType {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.module_type;
        }

        fn importModule(
            ptr: ?*anyopaque,
            _: std.mem.Allocator,
            _: []const u8,
            context: ?ImportContext,
        ) ImportError!api.TaggedModule {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            if (self.err != error.UnknownImportedModule) {
                if (context) |import_context| import_context.setRecognizedType(self.module_type);
            }
            return self.err;
        }

        fn implementation(self: *@This()) ModuleImplementation {
            return .{
                .ptr = self,
                .vtable = &implementation_vtable,
            };
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
            .import_module = importModule,
        };
    };

    var failed = Mock{ .module_type = .OpenVPN, .err = error.PassphraseRequired };
    var ignored = Mock{ .module_type = .WireGuard, .err = error.UnknownImportedModule };
    const implementations = [_]ModuleImplementation{
        failed.implementation(),
        ignored.implementation(),
    };

    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    var recognized_type: api.ModuleType = undefined;
    try std.testing.expectError(
        error.PassphraseRequired,
        registry.importModule(
            allocator,
            "contents",
            ImportContext.init(null, &recognized_type, null),
        ),
    );
    try std.testing.expectEqual(api.ModuleType.OpenVPN, recognized_type);
}

test "registry imports tagged profiles directly" {
    const allocator = std.testing.allocator;

    var registry = try Registry.init(allocator, &.{});
    defer registry.deinit(allocator);

    var imported = try registry.importProfile(
        allocator,
        \\{"version":2,"id":"00000000-0000-4000-8000-000000000000","name":"Existing","modules":[],"activeModulesIds":[]}
    ,
        null,
    );
    defer imported.deinit(allocator);

    try std.testing.expectEqualStrings("Existing", imported.name);
    try std.testing.expectEqual(@as(i32, api.profile_version), imported.version.?);
    try std.testing.expectEqual(@as(usize, 0), imported.modules.len);
}

test "registry migrates missing tagged profile versions" {
    const allocator = std.testing.allocator;

    var registry = try Registry.init(allocator, &.{});
    defer registry.deinit(allocator);

    var missing = try registry.importProfile(
        allocator,
        \\{"id":"00000000-0000-4000-8000-000000000000","name":"Missing","modules":[],"activeModulesIds":[]}
    ,
        null,
    );
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(i32, api.profile_version), missing.version.?);

    var null_version = try registry.importProfile(
        allocator,
        \\{"version":null,"id":"00000000-0000-4000-8000-000000000001","name":"Null","modules":[],"activeModulesIds":[]}
    ,
        null,
    );
    defer null_version.deinit(allocator);
    try std.testing.expectEqual(@as(i32, api.profile_version), null_version.version.?);
}

test "registry rejects invalid tagged profile versions" {
    const allocator = std.testing.allocator;

    var registry = try Registry.init(allocator, &.{});
    defer registry.deinit(allocator);

    try std.testing.expectError(
        error.InvalidProfile,
        registry.importProfile(
            allocator,
            \\{"version":999,"id":"00000000-0000-4000-8000-000000000000","name":"Future","modules":[],"activeModulesIds":[]}
        ,
            null,
        ),
    );
    try std.testing.expectError(
        error.InvalidProfile,
        registry.importProfile(
            allocator,
            \\{"version":-1,"id":"00000000-0000-4000-8000-000000000000","name":"Negative","modules":[],"activeModulesIds":[]}
        ,
            null,
        ),
    );
}

test "registry wraps tagged modules as active profiles" {
    const allocator = std.testing.allocator;

    var registry = try Registry.init(allocator, &.{});
    defer registry.deinit(allocator);

    var imported = try registry.importProfile(
        allocator,
        \\{"type":"DNS","value":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
    ,
        "Imported DNS",
    );
    defer imported.deinit(allocator);

    try std.testing.expectEqualStrings("Imported DNS", imported.name);
    try std.testing.expectEqual(@as(usize, 1), imported.modules.len);
    try std.testing.expectEqual(api.ModuleType.DNS, api.moduleType(&imported.modules[0]));
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", imported.active_modules_ids[0][0..]);
}

test "registry rejects non-profile JSON" {
    const allocator = std.testing.allocator;

    var registry = try Registry.init(allocator, &.{});
    defer registry.deinit(allocator);

    try std.testing.expectError(
        error.InvalidProfile,
        registry.importProfile(allocator, "[]", null),
    );
}

test "registry wraps encoded tagged modules as profiles" {
    const allocator = std.testing.allocator;
    var module = try api.parseModule(allocator,
        \\{"type":"DNS","value":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
    );
    defer module.deinit(allocator);

    const module_json = try api.encodeModule(allocator, module);
    defer allocator.free(module_json);
    try std.testing.expect(std.mem.indexOf(u8, module_json, "\"type\":\"DNS\"") != null);
    const module_id = api.moduleId(&module);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", module_id[0..]);

    var registry = try Registry.init(allocator, &.{});
    defer registry.deinit(allocator);

    var imported = try registry.importProfile(allocator, module_json, "Imported DNS");
    defer imported.deinit(allocator);

    try std.testing.expectEqualStrings("Imported DNS", imported.name);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", imported.active_modules_ids[0][0..]);
}

test "registry falls back to module importers for raw profiles" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        fn moduleType(_: ?*anyopaque) api.ModuleType {
            return .DNS;
        }

        fn importModule(
            _: ?*anyopaque,
            module_allocator: std.mem.Allocator,
            contents: []const u8,
            _: ?ImportContext,
        ) ImportError!api.TaggedModule {
            _ = contents;
            return api.parseModule(module_allocator,
                \\{"type":"DNS","value":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
            ) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Parsing,
                };
            };
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
            .import_module = importModule,
        };
    };

    const implementations = [_]ModuleImplementation{
        .{
            .vtable = &Mock.implementation_vtable,
        },
    };
    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    var imported = try registry.importProfile(allocator, "raw profile", "Imported DNS");
    defer imported.deinit(allocator);

    try std.testing.expectEqualStrings("Imported DNS", imported.name);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", imported.active_modules_ids[0][0..]);
}

test "registry imports raw modules through module importers" {
    const allocator = std.testing.allocator;

    const Mock = struct {
        fn moduleType(_: ?*anyopaque) api.ModuleType {
            return .DNS;
        }

        fn importModule(
            _: ?*anyopaque,
            module_allocator: std.mem.Allocator,
            contents: []const u8,
            _: ?ImportContext,
        ) ImportError!api.TaggedModule {
            _ = contents;
            return api.parseModule(module_allocator,
                \\{"type":"DNS","value":{"id":"11111111-1111-4111-8111-111111111111","protocolType":{"type":"cleartext"},"servers":["1.1.1.1"]}}
            ) catch |err| {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Parsing,
                };
            };
        }

        const implementation_vtable = ModuleImplementation.VTable{
            .module_type = moduleType,
            .import_module = importModule,
        };
    };

    const implementations = [_]ModuleImplementation{.{
        .vtable = &Mock.implementation_vtable,
    }};
    var registry = try Registry.init(allocator, &implementations);
    defer registry.deinit(allocator);

    var imported = try registry.importModule(allocator, "raw module", null);
    defer imported.deinit(allocator);

    try std.testing.expectEqual(api.ModuleType.DNS, api.moduleType(&imported));
    const imported_id = api.moduleId(&imported);
    try std.testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", imported_id[0..]);
}
