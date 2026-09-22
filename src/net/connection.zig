// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Abstractions around the way connections are created from
//! a module, provided that it supports creating a connection.

const std = @import("std");

const core = @import("../core/exports.zig");
const io = @import("io.zig");
const looper = @import("looper_runtime.zig");
const platform = @import("sandbox.zig");
const api = core.api;

const Looper = looper.Looper;

pub const CreateError = std.mem.Allocator.Error || error{
    IdGeneration,
    IncompleteModule,
    MissingConnectionImplementation,
    UnsupportedCryptoBackend,
};

pub const StartError = std.mem.Allocator.Error || error{
    DNSResolutionFailure,
    Timeout,
    UnableToStart,
};

/// Reports whether a connection may move directly between two statuses.
pub fn canChangeStatus(
    current: api.ConnectionStatus,
    next: api.ConnectionStatus,
) bool {
    if (current == next) return false;
    return switch (current) {
        .disconnected => next == .connecting,
        .connecting => next == .connected or
            next == .disconnecting or
            next == .disconnected,
        .connected => next == .disconnecting or next == .disconnected,
        .disconnecting => next == .disconnected,
    };
}

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

    pub fn deinit(self: *const ConnectionRegistry, allocator: std.mem.Allocator) void {
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
            .OpenVPN => |*module| module.requires_interactive_credentials orelse false,
            .WireGuard => false,
            else => false,
        };
    }
};

/// Returns the first active connection-building module in profile order.
pub fn activeConnectionModule(profile: *const api.Profile) ?ConnectionModule {
    const module = api.findActiveConnectionModule(profile) orelse return null;
    return .{ .module = module };
}

pub const RemoteDescriptor = struct {
    endpoint: core.api.ExtendedEndpoint,
    looper: *Looper,
};

/// A physical connection to a network service. A connection
/// may be started and stopped multiple times, and it emits
/// events through callbacks.
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const ShutdownReason = union(enum) {
        explicit_stop,
        failure: Events.FailureDisposition,
    };

    // FIXME: ###, Connections.VTable must not receive Events (get them from Sandbox on creation)
    // FIXME: ###, Connections must not know about looper

    pub const Events = struct {
        pub const Success = struct {
            remote_endpoint: api.ExtendedEndpoint,
            info: api.TunnelRemoteInfoWrapper,
        };
        pub const FailureDisposition = enum {
            reconnect,
            cancel,
        };
        pub const Failure = struct {
            code: api.PartoutErrorCode,
            disposition: FailureDisposition,
        };

        ctx: *anyopaque,

        // FIXME: ###, New v2 callbacks, temporary noops
        established: *const fn (*anyopaque, Success) void = struct {
            fn call(_: *anyopaque, _: Success) void {}
        }.call,
        failed: *const fn (*anyopaque, Failure) void = struct {
            fn call(_: *anyopaque, _: Failure) void {}
        }.call,
        stopped: *const fn (*anyopaque) void = struct {
            fn call(_: *anyopaque) void {}
        }.call,
        set_env: *const fn (*anyopaque, []const u8, ?[]const u8) void = struct {
            fn call(_: *anyopaque, _: []const u8, _: ?[]const u8) void {}
        }.call,

        data_count: *const fn (*anyopaque, api.DataCount) void,

        // Deprecated.
        status: *const fn (*anyopaque, api.ConnectionStatus) void,
        last_error: *const fn (*anyopaque, api.PartoutErrorCode) void,
        /// Requests host cancellation after an unrecoverable connection
        /// failure so the daemon can apply its cancellation policy.
        cancel: *const fn (*anyopaque, ?api.PartoutErrorCode) void,
    };

    pub const VTable = struct {
        // FIXME: ###, New v2 callbacks, temporary noops
        endpoints: *const fn (*anyopaque) []const api.ExtendedEndpoint = struct {
            fn call(_: *anyopaque) []const api.ExtendedEndpoint {
                return &.{};
            }
        }.call,
        start_v2: *const fn (*anyopaque, RemoteDescriptor) StartError!bool = struct {
            fn call(_: *anyopaque, _: RemoteDescriptor) StartError!bool {
                return false;
            }
        }.call,
        submit_packets: *const fn (*anyopaque, io.Side, Looper.Packets) Looper.ReadAction = struct {
            fn call(_: *anyopaque, _: io.Side, _: Looper.Packets) Looper.ReadAction {
                return .pause;
            }
        }.call,
        looper_failed: *const fn (*anyopaque, io.Side, Looper.Failure) void = struct {
            fn call(_: *anyopaque, _: io.Side, _: Looper.Failure) void {}
        }.call,
        looper_terminated: *const fn (*anyopaque, ?Looper.Failure) void = struct {
            fn call(_: *anyopaque, _: ?Looper.Failure) void {}
        }.call,

        /// Deprecated.
        start: *const fn (*anyopaque, Events) StartError!bool,

        /// Quiesces protocol activity and sends a best-effort exit notification
        /// while I/O is attached. Carries the owner's reason so finalization
        /// can preserve state needed for a retry. Does not release connection state.
        shutdown: *const fn (*anyopaque, ShutdownReason) void = struct {
            fn call(_: *anyopaque, _: ShutdownReason) void {}
        }.call,
        stop: *const fn (*anyopaque, u32, Events) void,

        /// Network reachability.
        network_change: *const fn (*anyopaque, io.ReachabilityInfo, Events) void,
        better_path: *const fn (*anyopaque, Events) void,
        /// Destroys this object. This is the very last step of the lifecycle.
        destroy: *const fn (*anyopaque) void,
    };

    pub fn endpoints(self: Connection) []const api.ExtendedEndpoint {
        return self.vtable.endpoints(self.ptr);
    }

    pub fn startV2(
        self: Connection,
        remote: RemoteDescriptor,
    ) StartError!bool {
        return self.vtable.start_v2(self.ptr, remote);
    }

    pub fn start(self: Connection, events: Events) StartError!bool {
        return self.vtable.start(self.ptr, events);
    }

    pub fn shutdown(self: Connection, reason: ShutdownReason) void {
        self.vtable.shutdown(self.ptr, reason);
    }

    /// Finalizes the connection after I/O is detached. No further events
    /// must be emitted after this returns.
    pub fn stop(
        self: Connection,
        timeout_ms: u32,
        events: Events,
    ) void {
        self.vtable.stop(self.ptr, timeout_ms, events);
    }

    pub fn submitPackets(
        self: Connection,
        side: io.Side,
        packets: Looper.Packets,
    ) Looper.ReadAction {
        return self.vtable.submit_packets(self.ptr, side, packets);
    }

    pub fn looperFailed(
        self: Connection,
        side: io.Side,
        failure: Looper.Failure,
    ) void {
        self.vtable.looper_failed(self.ptr, side, failure);
    }

    pub fn looperTerminated(
        self: Connection,
        failure: ?Looper.Failure,
    ) void {
        self.vtable.looper_terminated(self.ptr, failure);
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

    pub fn destroy(self: Connection) void {
        self.vtable.destroy(self.ptr);
    }
};
