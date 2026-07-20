// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! A connection operates within a sandbox to stay platform-agnostic.
//!
//! It's crucial that event handlers, when nullified, prevent further
//! events from being delivered to the subscriber.

const std = @import("std");

const core = @import("../core/exports.zig");
const io = @import("io.zig");
const api = core.api;
const TunWrapper = io.TunWrapper;

/// The sandbox is supplied by the daemon to a `ConnectionModule`
/// to make a connection within it.
pub const Sandbox = struct {
    profile: *const api.Profile,
    controller: TunnelController,
    resolver: DNSResolver,
    factory: SocketFactory,
    monitor: NetworkMonitor,
    /// Executes connection-owned work in the same serialized context as the
    /// connection lifecycle. The daemon supplies its actor-backed executor;
    /// direct users and tests default to immediate execution. The sandbox
    /// owner must keep this capability alive until the connection and every
    /// producer of submitted work have been drained.
    serialized_executor: SerializedExecutor = .{},
    options: ConnectionOptions = .{},
};

/// Interacts with the platform API to establish the physical
/// network tunnel. Reports snapshots of the current state.
pub const TunnelController = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    pub const Error = std.mem.Allocator.Error || error{
        SocketConfiguration,
        TunNotAvailable,
    };

    pub const VTable = struct {
        set_tunnel_settings: *const fn (?*anyopaque, api.TunnelRemoteInfoWrapper) Error!?TunWrapper,
        configure_sockets: *const fn (?*anyopaque, []const io.SocketDescriptor) Error!void,
        report_snapshot: *const fn (?*anyopaque, api.TunnelSnapshot) void,
        clear_tunnel_settings: *const fn (?*anyopaque, bool) void,
        set_reasserting: *const fn (?*anyopaque, bool) void,
        cancel_tunnel_connection: *const fn (?*anyopaque, ?api.PartoutErrorCode) void,
    };

    pub fn setTunnelSettings(self: TunnelController, info: api.TunnelRemoteInfoWrapper) Error!?TunWrapper {
        return self.vtable.set_tunnel_settings(self.ptr, info);
    }

    pub fn configureSockets(self: TunnelController, descriptors: []const io.SocketDescriptor) Error!void {
        return self.vtable.configure_sockets(self.ptr, descriptors);
    }

    pub fn reportSnapshot(self: TunnelController, snapshot: api.TunnelSnapshot) void {
        self.vtable.report_snapshot(self.ptr, snapshot);
    }

    pub fn clearTunnelSettings(self: TunnelController, with_kill_switch: bool) void {
        self.vtable.clear_tunnel_settings(self.ptr, with_kill_switch);
    }

    pub fn setReasserting(self: TunnelController, reasserting: bool) void {
        self.vtable.set_reasserting(self.ptr, reasserting);
    }

    pub fn cancelTunnelConnection(self: TunnelController, code: ?api.PartoutErrorCode) void {
        self.vtable.cancel_tunnel_connection(self.ptr, code);
    }
};

/// Provides portable DNS resolution.
pub const DNSResolver = struct {
    pub const Error = std.mem.Allocator.Error || error{
        NetworkUnreachable,
        ResolutionFailure,
        Timeout,
    };

    pub const Flag = enum {
        allAddresses,
    };

    ptr: ?*anyopaque = null,
    resolve_block: *const fn (
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        flags: std.EnumSet(Flag),
        reachability: ?io.ReachabilityInfo,
        timeout_ms: u32,
    ) Error![]DNSRecord,

    /// Optionally remaps an already-numeric address for the current network.
    ///
    /// This is primarily needed on DNS64 networks: Apple can translate a
    /// numeric IPv4 address to a synthesized IPv6 address whose prefix belongs
    /// to the active path. Keeping this capability on the resolver prevents
    /// protocol implementations from depending on platform DNS APIs.
    resolve_address_block: ?*const fn (
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        address: []const u8,
        reachability: ?io.ReachabilityInfo,
        timeout_ms: u32,
    ) Error![]u8 = null,

    pub fn resolve(
        self: *const DNSResolver,
        allocator: std.mem.Allocator,
        hostname: []const u8,
        flags: std.EnumSet(Flag),
        reachability: ?io.ReachabilityInfo,
        timeout_ms: u32,
    ) Error![]DNSRecord {
        return self.resolve_block(self.ptr, allocator, hostname, flags, reachability, timeout_ms);
    }

    /// Returns an owned address suitable for the current network. Resolvers
    /// without platform-specific address mapping simply preserve the input.
    pub fn resolveAddress(
        self: *const DNSResolver,
        allocator: std.mem.Allocator,
        address: []const u8,
        reachability: ?io.ReachabilityInfo,
        timeout_ms: u32,
    ) Error![]u8 {
        const block = self.resolve_address_block orelse return allocator.dupe(u8, address);
        return block(self.ptr, allocator, address, reachability, timeout_ms);
    }
};

/// Returned by a `DNSResolver`.
pub const DNSRecord = struct {
    address: []const u8,
    is_ipv6: bool,

    pub fn init(address: []const u8, is_ipv6: bool) DNSRecord {
        return .{
            .address = address,
            .is_ipv6 = is_ipv6,
        };
    }

    pub fn clone(self: DNSRecord, allocator: std.mem.Allocator) std.mem.Allocator.Error!DNSRecord {
        return .{
            .address = try allocator.dupe(u8, self.address),
            .is_ipv6 = self.is_ipv6,
        };
    }

    pub fn deinit(self: DNSRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
    }
};

/// Provides a factory of portable sockets, exposed as `IOInterface`.
pub const SocketFactory = struct {
    pub const Error = std.mem.Allocator.Error || error{
        LinkNotActive,
    };

    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        current_reachability: *const fn (?*anyopaque) ?io.ReachabilityInfo,
        create: *const fn (
            ptr: ?*anyopaque,
            allocator: std.mem.Allocator,
            endpoint: api.ExtendedEndpoint,
            reachability: ?io.ReachabilityInfo,
            timeout: c_int,
        ) Error!io.IOInterface,
    };

    pub fn currentReachability(self: SocketFactory) ?io.ReachabilityInfo {
        return self.vtable.current_reachability(self.ptr);
    }

    pub fn create(
        self: SocketFactory,
        allocator: std.mem.Allocator,
        endpoint: api.ExtendedEndpoint,
        reachability: ?io.ReachabilityInfo,
        timeout: u32,
    ) Error!io.IOInterface {
        return self.vtable.create(self.ptr, allocator, endpoint, reachability, timeout);
    }
};

/// Monitors network conditions used by the daemon and connections.
pub const NetworkMonitor = struct {
    ptr: ?*anyopaque = null,
    vtable: *const VTable,

    pub const EventHandler = struct {
        ptr: ?*anyopaque = null,
        on_reachability: *const fn (?*anyopaque, io.ReachabilityInfo) void,
        on_better_path: *const fn (?*anyopaque) void,

        /// Reports a new reachable network.
        pub fn onReachability(self: EventHandler, reachability: io.ReachabilityInfo) void {
            self.on_reachability(self.ptr, reachability);
        }

        /// Reports better path events, i.e., when a better network is available
        /// compared to the one we are connected to. For example, Wi-Fi or Ethernet
        /// are generally considered "better" than a mobile network.
        pub fn onBetterPath(self: EventHandler) void {
            self.on_better_path(self.ptr);
        }
    };

    pub const VTable = struct {
        start_observing: *const fn (?*anyopaque) void,
        stop_observing: *const fn (?*anyopaque) void,
        set_event_handler: *const fn (?*anyopaque, ?EventHandler) void,
        is_reachable: *const fn (?*anyopaque) bool,
    };

    pub fn startObserving(self: NetworkMonitor) void {
        self.vtable.start_observing(self.ptr);
    }

    pub fn stopObserving(self: NetworkMonitor) void {
        self.vtable.stop_observing(self.ptr);
    }

    pub fn setEventHandler(self: NetworkMonitor, handler: ?EventHandler) void {
        self.vtable.set_event_handler(self.ptr, handler);
    }

    pub fn isReachable(self: NetworkMonitor) bool {
        return self.vtable.is_reachable(self.ptr);
    }
};

/// Execution capability for work that must share the connection's serialized
/// lifecycle context. This is deliberately separate from connection events:
/// it schedules work rather than reporting an observation. Connections retain
/// this value at creation; lifecycle calls must not replace it.
pub const SerializedExecutor = struct {
    pub const Block = *const fn (*anyopaque) void;

    ptr: ?*anyopaque = null,
    run_block: *const fn (?*anyopaque, *anyopaque, Block) void = runInline,

    pub fn run(self: SerializedExecutor, block_ptr: *anyopaque, block: Block) void {
        self.run_block(self.ptr, block_ptr, block);
    }

    fn runInline(_: ?*anyopaque, block_ptr: *anyopaque, block: Block) void {
        block(block_ptr);
    }
};

/// Fine-tunes connection behavior within a `Sandbox`.
pub const ConnectionOptions = struct {
    /// The DNS resolution timeout, in milliseconds.
    dns_timeout: u32 = 3000,

    /// The link activity timeout, in milliseconds.
    link_activity_timeout: u32 = 5000,

    /// The link write timeout, in milliseconds.
    link_write_timeout: u32 = 5000,

    /// The minimum interval before updating data count, in milliseconds.
    min_data_count_interval: u32 = 1000,

    /// Generic user data represented as JSON.
    user_info: ?api.JSONValue = null,
};
