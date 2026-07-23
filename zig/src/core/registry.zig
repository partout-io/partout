// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const api = @import("api.zig");
const log = @import("logging.zig");
const util = @import("util.zig");
const uuid = @import("uuid.zig");

/// Errors returned while importing profiles or modules from serialized input.
pub const ImportError = error{
    IdGeneration,
    InvalidJson,
    InvalidProfile,
    OutOfMemory,
    Parsing,
    PassphraseRequired,
    UnknownImportedModule,
};

/// Caller-provided context for module importers.
///
/// The registry probes multiple importers for raw input before it knows the
/// module type. `parse_error_info` is generic metadata for every importer,
/// `recognized_type` receives the type of a recognized import outcome, while
/// `ptr` is optional importer-specific context guarded by `module_type`.
/// The module implementation stamps `module_type` on a copy for the duration of
/// each importer callback.
pub const ImportContext = struct {
    module_type: ?api.ModuleType = null,
    parse_error_info: ?*api.ParseErrorInfo = null,
    recognized_type: ?*api.ModuleType = null,
    ptr: ?*const anyopaque = null,

    pub fn init(
        parse_error_info: ?*api.ParseErrorInfo,
        recognized_type: ?*api.ModuleType,
        ptr: ?*const anyopaque,
    ) ImportContext {
        return .{
            .parse_error_info = parse_error_info,
            .recognized_type = recognized_type,
            .ptr = ptr,
        };
    }

    pub fn withModuleType(
        self: ImportContext,
        module_type: api.ModuleType,
    ) ImportContext {
        var result = self;
        result.module_type = module_type;
        return result;
    }

    pub fn cast(
        self: ImportContext,
        comptime Context: type,
        module_type: api.ModuleType,
    ) ?*const Context {
        const active_module_type = self.module_type orelse return null;
        if (active_module_type != module_type) return null;
        const ptr = self.ptr orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn setRecognizedType(
        self: ImportContext,
        module_type: api.ModuleType,
    ) void {
        const recognized_type = self.recognized_type orelse return;
        recognized_type.* = module_type;
    }
};

/// Errors returned while serializing modules to native text formats.
pub const SerializeError = error{
    IncompleteModule,
    MissingModuleSerializer,
    OutOfMemory,
    SerializationFailed,
    UnexpectedModuleType,
};

/// Runtime adapter for a module implementation.
///
/// Implementations advertise one schema module type and may optionally provide
/// importers and serializers for native or third-party profile formats.
pub const ModuleImplementation = struct {
    /// Opaque implementation state passed to every vtable callback.
    ptr: ?*anyopaque = null,
    /// Function table backing this implementation.
    vtable: *const VTable,

    /// Callback table for a module implementation.
    pub const VTable = struct {
        /// Returns the module type handled by this implementation.
        module_type: *const fn (?*anyopaque) api.ModuleType,
        /// Attempts to import `contents` as a tagged module.
        ///
        /// Return `error.UnknownImportedModule` when the input is not recognized
        /// so the registry can continue probing other implementations.
        /// `context` is optional caller-provided context for importers that need it.
        import_module: ?*const fn (
            ?*anyopaque,
            std.mem.Allocator,
            []const u8,
            ?ImportContext,
        ) ImportError!api.TaggedModule = null,
        /// Serializes `module` to this implementation's native text format.
        ///
        /// The returned buffer is allocated with the provided allocator and
        /// must be freed by the caller.
        serialize_module: ?*const fn (
            ?*anyopaque,
            std.mem.Allocator,
            *const api.TaggedModule,
            ?*anyopaque,
        ) SerializeError![]u8 = null,
    };

    /// Returns the schema module type advertised by this implementation.
    pub fn moduleType(self: ModuleImplementation) api.ModuleType {
        return self.vtable.module_type(self.ptr);
    }

    /// Imports a tagged module through this implementation.
    ///
    /// Implementations without an importer report `error.UnknownImportedModule`.
    pub fn importModule(
        self: ModuleImplementation,
        allocator: std.mem.Allocator,
        contents: []const u8,
        context: ?ImportContext,
    ) ImportError!api.TaggedModule {
        const importer = self.vtable.import_module orelse return error.UnknownImportedModule;
        const import_context = if (context) |value| value.withModuleType(self.moduleType()) else null;
        return importer(self.ptr, allocator, contents, import_context);
    }

    /// Serializes a tagged module through this implementation.
    ///
    /// Implementations without a serializer report
    /// `error.MissingModuleSerializer`.
    pub fn serializeModule(
        self: ModuleImplementation,
        allocator: std.mem.Allocator,
        module: *const api.TaggedModule,
        object: ?*anyopaque,
    ) SerializeError![]u8 {
        if (api.moduleType(module) != self.moduleType()) return error.UnexpectedModuleType;
        const serializer = self.vtable.serialize_module orelse return error.MissingModuleSerializer;
        return serializer(self.ptr, allocator, module, object);
    }
};

/// Registry of module implementations available to the importer.
///
/// The registry owns a de-duplicated copy of the implementation list supplied
/// at initialization time.
pub const Registry = struct {
    /// Owned slice of implementations, with at most one entry per module type.
    all_implementations: []ModuleImplementation,

    /// Builds a registry from implementation descriptors.
    ///
    /// When multiple implementations advertise the same module type, the later
    /// descriptor replaces the earlier one.
    pub fn init(
        allocator: std.mem.Allocator,
        all_implementations: []const ModuleImplementation,
    ) error{OutOfMemory}!Registry {
        var implementations: std.ArrayList(ModuleImplementation) = .empty;
        errdefer implementations.deinit(allocator);

        for (all_implementations) |impl| {
            if (implementationIndex(implementations.items, impl.moduleType())) |index| {
                implementations.items[index] = impl;
            } else {
                try implementations.append(allocator, impl);
            }
        }

        return .{
            .all_implementations = try implementations.toOwnedSlice(allocator),
        };
    }

    /// Releases memory allocated by `init`.
    pub fn deinit(self: *const Registry, allocator: std.mem.Allocator) void {
        allocator.free(self.all_implementations);
    }

    /// Returns the implementation registered for `module_type`, if any.
    pub fn implementation(
        self: Registry,
        module_type: api.ModuleType,
    ) ?ModuleImplementation {
        const index = implementationIndex(self.all_implementations, module_type) orelse return null;
        return self.all_implementations[index];
    }

    /// Imports a tagged module by probing registered importers in order.
    ///
    /// `error.UnknownImportedModule` means an importer declined the input and
    /// probing should continue. If no importer succeeds, the first concrete
    /// importer error is returned; if every importer only declined, parsing
    /// fails with `error.Parsing`.
    pub fn importModule(
        self: Registry,
        allocator: std.mem.Allocator,
        contents: []const u8,
        context: ?ImportContext,
    ) ImportError!api.TaggedModule {
        var was_handled = false;
        var first_error: ?ImportError = null;

        for (self.all_implementations) |impl| {
            if (impl.vtable.import_module == null) continue;
            was_handled = true;
            return impl.importModule(allocator, contents, context) catch |err| {
                switch (err) {
                    error.UnknownImportedModule => {},
                    else => if (first_error == null) {
                        first_error = err;
                    },
                }
                continue;
            };
        }

        if (first_error) |err| return err;
        if (!was_handled) return error.UnknownImportedModule;
        return error.Parsing;
    }

    /// Imports a profile from canonical JSON, tagged-module JSON, or raw input.
    ///
    /// Canonical profiles are returned directly. Tagged modules and raw modules
    /// accepted by registered importers are wrapped into a single-module profile
    /// whose active module is the imported module.
    pub fn importProfile(
        self: Registry,
        allocator: std.mem.Allocator,
        text: []const u8,
        name: ?[]const u8,
    ) ImportError!api.Profile {
        // If the input is not a JSON, parse it as Module
        log.write(.debug, "Parse profile as JSON");
        var parsed = util.parseJsonValue(allocator, text) catch |json_err| {
            switch (json_err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidJson => {
                    log.writef(.debug, "Unable to parse JSON, parse profile from text: {}", .{json_err});
                    return self.importModuleAsProfile(allocator, text, name);
                },
            }
        };
        defer parsed.deinit();

        // Try to parse the JSON as profile, and return it on success
        var profile = api.Profile.parseValue(allocator, parsed.value) catch |profile_err| {
            if (profile_err == error.OutOfMemory) return error.OutOfMemory;

            // The JSON is not a profile, parse it as module
            log.writef(.debug, "Unable to parse profile JSON, parse as module: {}", .{profile_err});
            var module = api.TaggedModule.parseValue(allocator, parsed.value) catch |module_err| {
                return switch (module_err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidJson,
                    error.InvalidModel,
                    error.UnsupportedModel,
                    => {
                        log.writef(.err, "Unable to parse module JSON, fail: {}", .{module_err});
                        return ImportError.InvalidProfile;
                    },
                };
            };
            errdefer module.deinit(allocator);

            // Return profile with parsed module
            return profileWithActiveModule(allocator, &module, name);
        };
        errdefer profile.deinit(allocator);
        try migrateProfileVersion(&profile);
        return profile;
    }

    fn importModuleAsProfile(
        self: Registry,
        allocator: std.mem.Allocator,
        text: []const u8,
        name: ?[]const u8,
    ) ImportError!api.Profile {
        // Require a successful module import, otherwise the profile is invalid
        var module = self.importModule(allocator, text, null) catch |module_err| {
            return switch (module_err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidProfile,
            };
        };
        errdefer module.deinit(allocator);

        // Valid module, return a profile with it
        return profileWithActiveModule(allocator, &module, name);
    }

    /// Serializes a tagged module through the implementation registered for
    /// its module type.
    pub fn serializeModule(
        self: Registry,
        allocator: std.mem.Allocator,
        module: *const api.TaggedModule,
        object: ?*anyopaque,
    ) SerializeError![]u8 {
        const impl = self.implementation(api.moduleType(module)) orelse return error.MissingModuleSerializer;
        return impl.serializeModule(allocator, module, object);
    }
};

/// Migrates supported imported profile versions to the current schema version.
fn migrateProfileVersion(profile: *api.Profile) ImportError!void {
    const current_version: i32 = api.profile_version;
    if (profile.version) |version| {
        if (version < 0 or version > current_version) return error.InvalidProfile;
    }
    profile.version = current_version;
}

/// Returns the index of the implementation for `module_type`.
fn implementationIndex(
    implementations: []const ModuleImplementation,
    module_type: api.ModuleType,
) ?usize {
    for (implementations, 0..) |implementation, index| {
        if (implementation.moduleType() == module_type) return index;
    }
    return null;
}

/// Builds a profile containing a single active module.
fn profileWithActiveModule(
    allocator: std.mem.Allocator,
    module: *const api.TaggedModule,
    name: ?[]const u8,
) ImportError!api.Profile {
    const active_id = api.moduleId(module);
    const profile_id = try uuid.newId();
    const profile_name = try allocator.dupe(u8, name orelse "");
    errdefer allocator.free(profile_name);

    // Make a list of 1 module
    const modules = try allocator.alloc(api.TaggedModule, 1);
    errdefer allocator.free(modules);
    // Let the module be the only active one
    const active_modules_ids = try allocator.alloc(uuid.UUID, 1);
    errdefer allocator.free(active_modules_ids);
    active_modules_ids[0] = active_id;

    // Transfer module ownership only after every allocation has succeeded.
    // Both callers return immediately, so their errdefer only runs when this
    // function fails before the transfer.
    modules[0] = module.*;

    return .{
        .version = api.profile_version,
        .id = profile_id,
        .name = profile_name,
        .modules = modules,
        .active_modules_ids = active_modules_ids,
    };
}
