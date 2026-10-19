// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Abstractions around the way connections are created from
//! a module, provided that it supports creating a connection.

const std = @import("std");

const core = @import("../core/exports.zig");
const io = @import("io.zig");
const events_mod = @import("connection_events.zig");
const platform = @import("sandbox.zig");
const api = core.api;

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
    /// Absent in none mode, transferred in link mode, borrowed in looper mode.
    link: ?io.LinkDescriptor = null,
    endpoint: ?io.SocketEndpoint = null,
    local_port: u16 = 0,
};

/// A physical connection to a network service. A connection
/// may be started and stopped multiple times, and it emits
/// events through callbacks.
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Selects the daemon's responsibility for socket creation and packet I/O.
    daemon_io: DaemonIO = .looper,

    /// Requested bind port for an unconnected link; zero selects an ephemeral port.
    local_port: u16 = 0,

    pub const DaemonIO = enum {
        /// The connection/backend creates sockets and performs all packet I/O.
        /// The daemon creates TUN and transfers it through commit().
        none,
        /// The daemon creates sockets and TUN, then transfers them to the connection.
        link,
        /// The daemon creates sockets and TUN; the looper owns their lifetime and I/O.
        looper,
    };

    pub const StartResult = union(enum) {
        /// Startup is pending; establishment will arrive through Events.
        started,
        /// Synchronous establishment. The caller owns info and must deinit it
        /// with the connection's allocator after applying settings and commit.
        established: Events.Success,
        failed,
    };

    pub const ShutdownReason = union(enum) {
        explicit_stop,
        /// Graceful restart requested by needs_rebind.
        rebind,
        failure: Events.FailureDisposition,
    };

    pub const Event = events_mod.ConnectionEvent;
    pub const Events = events_mod.ConnectionEvents;

    pub const VTable = struct {
        /// Null selects an unconnected UDP socket and skips endpoint resolution.
        endpoints: *const fn (*anyopaque) ?[]const api.ExtendedEndpoint = struct {
            fn call(_: *anyopaque) ?[]const api.ExtendedEndpoint {
                return null;
            }
        }.call,
        /// In link mode, takes link ownership on entry, including on failure.
        /// Return established instead of emitting Events.established when startup
        /// completes synchronously; its info ownership transfers to the caller.
        start: *const fn (*anyopaque, RemoteDescriptor) StartError!StartResult = struct {
            fn call(_: *anyopaque, _: RemoteDescriptor) StartError!StartResult {
                return .failed;
            }
        }.call,
        /// Commits TUN after synchronous establishment or the established event.
        /// Takes TUN ownership on entry, including on failure. The daemon calls
        /// this only when the connection performs packet I/O, outside looper mode.
        commit: *const fn (*anyopaque, io.TunDescriptor) StartError!void = struct {
            fn call(_: *anyopaque, tun: io.TunDescriptor) StartError!void {
                var owned = tun;
                owned.cleanup();
            }
        }.call,
        /// Replaces the link and optional TUN, retaining session state.
        /// Null requests a graceful session restart instead of an in-place rebind.
        /// Takes optional TUN ownership on entry, including on failure, except in
        /// looper mode where it is borrowed. In link mode, also takes link ownership.
        rebind: ?*const fn (*anyopaque, RemoteDescriptor, ?io.TunDescriptor) StartError!bool = null,
        /// Sources accompany unconnected UDP reads, one per packet; otherwise null.
        submit_packets: *const fn (*anyopaque, io.Side, io.Packets, ?[]const io.SocketAddress) io.ReadAction = struct {
            fn call(_: *anyopaque, _: io.Side, _: io.Packets, _: ?[]const io.SocketAddress) io.ReadAction {
                return .pause;
            }
        }.call,
        looper_failed: *const fn (*anyopaque, io.Side, io.Failure) void = struct {
            fn call(_: *anyopaque, _: io.Side, _: io.Failure) void {}
        }.call,
        looper_terminated: *const fn (*anyopaque, ?io.Failure) void = struct {
            fn call(_: *anyopaque, _: ?io.Failure) void {}
        }.call,

        /// Quiesces protocol activity and sends a best-effort exit notification
        /// while I/O is attached. Carries the owner's reason so finalization
        /// can preserve state needed for a retry. Does not release connection state.
        shutdown: *const fn (*anyopaque, ShutdownReason) void = struct {
            fn call(_: *anyopaque, _: ShutdownReason) void {}
        }.call,
        stop: *const fn (*anyopaque, Events) void,

        /// A refresh pauses link submissions and receives a replacement through
        /// rebind, retaining TUN without re-establishing the connection when supported.
        network_change: *const fn (*anyopaque, io.ReachabilityInfo, Events) void,
        better_path: *const fn (*anyopaque, Events) void,
        /// Destroys this object. This is the very last step of the lifecycle.
        destroy: *const fn (*anyopaque) void,
    };

    pub fn endpoints(self: Connection) ?[]const api.ExtendedEndpoint {
        return self.vtable.endpoints(self.ptr);
    }

    pub fn start(
        self: Connection,
        remote: RemoteDescriptor,
    ) StartError!StartResult {
        return self.vtable.start(self.ptr, remote);
    }

    pub fn commit(self: Connection, tun: io.TunDescriptor) StartError!void {
        return self.vtable.commit(self.ptr, tun);
    }

    pub fn rebind(self: Connection, remote: RemoteDescriptor, tun: ?io.TunDescriptor) StartError!bool {
        const callback = self.vtable.rebind orelse return false;
        return callback(self.ptr, remote, tun);
    }

    pub fn shutdown(self: Connection, reason: ShutdownReason) void {
        self.vtable.shutdown(self.ptr, reason);
    }

    /// Finalizes the connection after I/O is detached. No further events
    /// must be emitted after this returns.
    pub fn stop(self: Connection, events: Events) void {
        self.vtable.stop(self.ptr, events);
    }

    pub fn submitPackets(
        self: Connection,
        side: io.Side,
        packets: io.Packets,
        sources: ?[]const io.SocketAddress,
    ) io.ReadAction {
        return self.vtable.submit_packets(self.ptr, side, packets, sources);
    }

    pub fn looperFailed(
        self: Connection,
        side: io.Side,
        failure: io.Failure,
    ) void {
        self.vtable.looper_failed(self.ptr, side, failure);
    }

    pub fn looperTerminated(
        self: Connection,
        failure: ?io.Failure,
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
