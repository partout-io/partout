// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Abstractions around the way connections are created from
//! a module, provided that it supports creating a connection.

const std = @import("std");

const core = @import("../core/exports.zig");
const io = @import("io.zig");
const platform = @import("sandbox.zig");
const api = core.api;

pub const CreateError = std.mem.Allocator.Error || error{
    IdGeneration,
    IncompleteModule,
    MissingConnectionImplementation,
};

pub const StartError = std.mem.Allocator.Error || error{
    UnableToStart,
};

/// Manages a set of supported implementations to pick the right
/// one to build a connection with. The goal of the registry is
/// to couple a module with a sandbox to establish a
/// physical `Connection`.
pub const ConnectionRegistry = struct {
    all_implementations: []ConnectionImplementation,

    pub fn init(
        allocator: std.mem.Allocator,
        all_implementations: []const ConnectionImplementation,
    ) error{OutOfMemory}!ConnectionRegistry {
        var implementations: std.ArrayList(ConnectionImplementation) = .empty;
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

    pub fn deinit(self: *ConnectionRegistry, allocator: std.mem.Allocator) void {
        allocator.free(self.all_implementations);
    }

    pub fn implementation(
        self: ConnectionRegistry,
        module_type: api.ModuleType,
    ) ?ConnectionImplementation {
        const index = implementationIndex(self.all_implementations, module_type) orelse return null;
        return self.all_implementations[index];
    }

    pub fn createConnection(
        self: ConnectionRegistry,
        allocator: std.mem.Allocator,
        module: ConnectionModule,
        sandbox: platform.Sandbox,
    ) CreateError!Connection {
        const impl = self.implementation(module.typeOf()) orelse return error.MissingConnectionImplementation;
        return impl.createConnection(allocator, module, sandbox);
    }

    fn implementationIndex(
        implementations: []const ConnectionImplementation,
        module_type: api.ModuleType,
    ) ?usize {
        for (implementations, 0..) |impl, index| {
            if (impl.moduleType() == module_type) return index;
        }
        return null;
    }
};

pub const ConnectionImplementation = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    pub const Factory = *const fn (
        ?*anyopaque,
        std.mem.Allocator,
        ConnectionModule,
        platform.Sandbox,
    ) CreateError!Connection;

    pub const VTable = struct {
        module_type: *const fn (?*anyopaque) api.ModuleType,
        create_connection: Factory,
    };

    pub fn moduleType(self: ConnectionImplementation) api.ModuleType {
        return self.vtable.module_type(self.ptr);
    }

    pub fn createConnection(
        self: ConnectionImplementation,
        allocator: std.mem.Allocator,
        module: ConnectionModule,
        sandbox: platform.Sandbox,
    ) CreateError!Connection {
        return self.vtable.create_connection(self.ptr, allocator, module, sandbox);
    }
};

/// View over a module that can establish a connection.
pub const ConnectionModule = struct {
    /// Borrowed pointer into the owning profile.
    module: *const api.TaggedModule,

    /// Returns the schema id of the wrapped module.
    pub fn id(self: ConnectionModule) api.UUID {
        return api.moduleId(self.module);
    }

    /// Returns the module type represented by the tagged union case.
    pub fn typeOf(self: ConnectionModule) api.ModuleType {
        return api.moduleType(self.module);
    }

    /// Reports whether this module requires credentials at connection time.
    ///
    /// Only OpenVPN currently exposes this flag; WireGuard is never
    /// interactive.
    pub fn isInteractive(self: ConnectionModule) bool {
        return switch (self.module.*) {
            .OpenVPN => |module| module.requires_interactive_credentials orelse false,
            .WireGuard => false,
            else => false,
        };
    }
};

/// Returns the first active connection-building module in profile order.
pub fn activeConnectionModule(profile: api.Profile) ?ConnectionModule {
    const module = api.findActiveConnectionModule(profile) orelse return null;
    return .{ .module = module };
}

/// A physical connection to a network service. A connection
/// may be started and stopped multiple times, and it emits
/// events through callbacks.
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Events = struct {
        ctx: *anyopaque,
        status: *const fn (*anyopaque, api.ConnectionStatus) void,
        last_error: *const fn (*anyopaque, api.PartoutErrorCode) void,
        data_count: *const fn (*anyopaque, api.DataCount) void,
        remove_key: *const fn (*anyopaque, EventKey) void,
    };

    pub const EventKey = enum {
        connection_status,
        data_count,
        last_error_code,
    };

    pub const VTable = struct {
        start: *const fn (*anyopaque, Events) StartError!bool,
        stop: *const fn (*anyopaque, u32, Events) void,
        network_change: *const fn (*anyopaque, io.ReachabilityInfo, Events) void,
        better_path: *const fn (*anyopaque, Events) void,
        deinit: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn start(self: Connection, events: Events) StartError!bool {
        return self.vtable.start(self.ptr, events);
    }

    /// Stops the connection. No further events must be emitted.
    pub fn stop(
        self: Connection,
        timeout_ms: u32,
        events: Events,
    ) void {
        self.vtable.stop(self.ptr, timeout_ms, events);
    }

    pub fn networkChange(
        self: Connection,
        reachability: io.ReachabilityInfo,
        events: Events,
    ) void {
        self.vtable.network_change(self.ptr, reachability, events);
    }

    pub fn betterPath(self: Connection, events: Events) void {
        self.vtable.better_path(self.ptr, events);
    }

    pub fn deinit(self: Connection, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};
