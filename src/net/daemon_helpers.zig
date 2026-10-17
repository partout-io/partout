// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const core = @import("../core/exports.zig");
const connection = @import("connection.zig");
const io = @import("io.zig");
const resolver_mod = @import("resolver.zig");
const sandbox = @import("sandbox.zig");

const api = core.api;
const log = core.logging;

pub const ConnectionGate = struct {
    pub const ReachabilityBlock = struct {
        ptr: ?*const anyopaque = null,
        is_reachable: *const fn (?*const anyopaque) bool,

        fn isReachable(self: ReachabilityBlock) bool {
            return self.is_reachable(self.ptr);
        }
    };

    pub const OnReadyBlock = struct {
        ptr: ?*anyopaque = null,
        notify: *const fn (?*anyopaque) void,

        fn call(self: OnReadyBlock) void {
            self.notify(self.ptr);
        }
    };

    const State = struct {
        enabled: bool,
        network_available: bool,
        connection_status: api.ConnectionStatus,

        fn isReady(self: *const State) bool {
            return self.enabled and
                self.network_available and
                self.connection_status == .disconnected;
        }
    };

    const Submission = struct {
        is_ready: bool,
        did_change: bool,
        state: State,
        on_ready: ?OnReadyBlock,

        fn callAndReturn(self: *const Submission) bool {
            if (self.did_change) {
                log.writef(.info, "ConnectionGate.onReady({{signal={}, network={}, status={s}}}) -> {}", .{
                    self.state.enabled,
                    self.state.network_available,
                    self.state.connection_status.raw(),
                    self.is_ready,
                });
            }
            if (self.on_ready) |handler| handler.call();
            return self.is_ready;
        }
    };

    mutex: core.Mutex,
    reachability_block: ReachabilityBlock,
    on_ready: ?OnReadyBlock,
    observing: bool,
    state: State,

    pub fn init(reachability_block: ?ReachabilityBlock) ConnectionGate {
        return .{
            .mutex = .{},
            .reachability_block = reachability_block orelse .{
                .is_reachable = neverReachable,
            },
            .on_ready = null,
            .observing = false,
            .state = .{
                .enabled = false,
                .network_available = false,
                .connection_status = .disconnected,
            },
        };
    }

    pub fn deinit(self: *ConnectionGate) void {
        self.mutex.deinit();
        log.write(.debug, "Deinit ConnectionGate");
    }

    pub fn setReadyHandler(self: *ConnectionGate, handler: ?OnReadyBlock) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.on_ready = handler;
    }

    pub fn setReachabilityBlock(self: *ConnectionGate, block: ?ReachabilityBlock) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.reachability_block = block orelse .{
            .is_reachable = neverReachable,
        };
    }

    fn neverReachable(_: ?*const anyopaque) bool {
        return false;
    }

    pub fn startObserving(self: *ConnectionGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.observing) return;
        self.state.network_available = self.reachability_block.isReachable();
        self.observing = true;
    }

    pub fn stopObserving(self: *ConnectionGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.observing) {
            self.state.enabled = false;
            self.on_ready = null;
            return;
        }
        self.state.enabled = false;
        self.on_ready = null;
        self.observing = false;
    }

    pub fn setEnabled(self: *ConnectionGate, enabled: bool) bool {
        // Changes .enabled + .network_available
        self.mutex.lock();
        const submission = self.submitLocked(.{
            .enabled = enabled,
            .network_available = self.reachability_block.isReachable(),
            .connection_status = self.state.connection_status,
        });
        self.mutex.unlock();

        return submission.callAndReturn();
    }

    pub fn updateReachability(self: *ConnectionGate, reachable: bool) bool {
        // Changes .network_available
        self.mutex.lock();
        const submission = self.submitLocked(.{
            .enabled = self.state.enabled,
            .network_available = reachable,
            .connection_status = self.state.connection_status,
        });
        self.mutex.unlock();

        return submission.callAndReturn();
    }

    pub fn updateStatus(self: *ConnectionGate, status: api.ConnectionStatus) bool {
        // Changes .connection_status + latest .network_available
        self.mutex.lock();
        const submission = self.submitLocked(.{
            .enabled = self.state.enabled,
            .network_available = self.reachability_block.isReachable(),
            .connection_status = status,
        });
        self.mutex.unlock();

        return submission.callAndReturn();
    }

    pub fn isReady(self: *ConnectionGate) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.state.isReady();
    }

    fn submitLocked(self: *ConnectionGate, new_state: State) Submission {
        if (std.meta.eql(self.state, new_state)) {
            return .{
                .is_ready = false,
                .did_change = false,
                .state = self.state,
                .on_ready = null,
            };
        }
        self.state = new_state;
        // Call private non-locking version, self.isReady() WOULD DEADLOCK
        const is_ready = self.state.isReady();
        return .{
            .is_ready = is_ready,
            .did_change = true,
            .state = self.state,
            .on_ready = if (is_ready) self.on_ready else null,
        };
    }
};

pub const SnapshotPublisher = struct {
    const ProfileId = api.UUID;
    const ReportBlock = *const fn (*const anyopaque, api.TunnelSnapshot) void;

    allocator: std.mem.Allocator,
    /// Owned copy, independent of the connection callback's lifetime.
    last_error: ?api.PartoutErrorPair = null,
    profile_id: ProfileId,
    report_snapshot: ReportBlock,
    report_snapshot_ctx: *const anyopaque,
    min_data_count_delta: u64,
    environment: api.TunnelSnapshotEnvironment = emptyEnvironment(),
    last_published_snapshot: ?api.TunnelSnapshot = null,

    pub fn init(
        allocator: std.mem.Allocator,
        profile_id: ProfileId,
        report_snapshot: ReportBlock,
        report_snapshot_ctx: *const anyopaque,
        min_data_count_delta: u64,
    ) SnapshotPublisher {
        return .{
            .allocator = allocator,
            .profile_id = profile_id,
            .report_snapshot = report_snapshot,
            .report_snapshot_ctx = report_snapshot_ctx,
            .min_data_count_delta = min_data_count_delta,
        };
    }

    pub fn deinit(self: *SnapshotPublisher) void {
        if (self.last_error) |value| value.deinit(self.allocator);
    }

    pub fn clearEnvironment(self: *SnapshotPublisher) void {
        self.setLastError(null);
        self.environment = emptyEnvironment();
    }

    pub fn setConnectionStatus(self: *SnapshotPublisher, status: api.ConnectionStatus) void {
        self.environment.connection_status = status;
    }

    pub fn setLastError(self: *SnapshotPublisher, err_pair: ?api.PartoutErrorPair) void {
        if (api.errorPairEqual(self.last_error, err_pair)) return;

        const next: ?api.PartoutErrorPair = if (err_pair) |value|
            value.clone(self.allocator) catch .{ .code = .outOfMemory }
        else
            null;
        if (self.last_error) |previous| previous.deinit(self.allocator);
        self.last_error = next;
        self.last_published_snapshot = null;
    }

    pub fn setDataCount(self: *SnapshotPublisher, data_count: api.DataCount) void {
        self.environment.data_count = data_count;
    }

    pub fn publishCurrentSnapshot(self: *SnapshotPublisher, force: bool) void {
        var snapshot = api.TunnelSnapshot{
            .id = self.profile_id,
            .is_enabled = true,
            .status = tunnelStatus(self.environment.connection_status),
            .on_demand = false,
            .environment = self.environment,
        };
        if (!self.shouldPublishSnapshot(snapshot, force)) return;

        const formatted = if (self.last_error) |err_pair|
            api.errorPairFormatZ(self.allocator, err_pair) catch return
        else
            null;
        defer if (formatted) |value| self.allocator.free(value);

        self.last_published_snapshot = snapshot;
        // Only the delivered snapshot borrows the temporary wire representation.
        snapshot.environment.?.last_error_code = formatted;
        self.report_snapshot(self.report_snapshot_ctx, snapshot);
    }

    fn shouldPublishSnapshot(
        self: *const SnapshotPublisher,
        snapshot: api.TunnelSnapshot,
        force: bool,
    ) bool {
        if (force or self.min_data_count_delta == 0) return true;
        const last_published_snapshot = self.last_published_snapshot orelse return true;
        if (!isEquivalentExceptDataCount(snapshot, last_published_snapshot)) return true;

        const data_count = if (snapshot.environment) |env| env.data_count else api.DataCount{};
        const last_data_count = if (last_published_snapshot.environment) |env| env.data_count else api.DataCount{};
        return dataCountDelta(data_count, last_data_count) >= self.min_data_count_delta;
    }

    fn emptyEnvironment() api.TunnelSnapshotEnvironment {
        return .{
            .connection_status = .disconnected,
            .data_count = .{},
            .last_error_code = null,
        };
    }

    fn tunnelStatus(status: api.ConnectionStatus) api.TunnelStatus {
        return switch (status) {
            .disconnected => .inactive,
            .connecting => .activating,
            .connected => .active,
            .disconnecting => .deactivating,
        };
    }

    fn isEquivalentExceptDataCount(
        lhs: api.TunnelSnapshot,
        rhs: api.TunnelSnapshot,
    ) bool {
        if (!std.mem.eql(u8, lhs.id[0..], rhs.id[0..])) return false;
        if (lhs.is_enabled != rhs.is_enabled) return false;
        if (lhs.status != rhs.status) return false;
        if (lhs.on_demand != rhs.on_demand) return false;
        return environmentsEquivalentExceptDataCount(lhs.environment, rhs.environment);
    }

    fn environmentsEquivalentExceptDataCount(
        lhs: ?api.TunnelSnapshotEnvironment,
        rhs: ?api.TunnelSnapshotEnvironment,
    ) bool {
        if (lhs == null or rhs == null) return lhs == null and rhs == null;

        const lhs_env = lhs.?;
        const rhs_env = rhs.?;
        if (lhs_env.connection_status != rhs_env.connection_status) return false;
        return core.util.optionalStringsEqual(lhs_env.last_error_code, rhs_env.last_error_code);
    }

    fn dataCountDelta(lhs: api.DataCount, rhs: api.DataCount) u64 {
        const received_delta = uintDelta(lhs.received, rhs.received);
        const sent_delta = uintDelta(lhs.sent, rhs.sent);
        return std.math.add(u64, received_delta, sent_delta) catch std.math.maxInt(u64);
    }

    fn uintDelta(lhs: u64, rhs: u64) u64 {
        return if (lhs >= rhs) lhs - rhs else rhs - lhs;
    }
};

/// Serial link preparation, independent of Connection and its event loop.
/// Owns endpoint storage and DNS state until destroy() joins the worker.
pub const ConnectionWorker = struct {
    pub const Action = enum { start, rebind };
    pub const Request = struct {
        request_id: u64,
        action: Action,
        local_port: u16,
        reachability: ?io.ReachabilityInfo,
        connect_udp: bool,
        dns_timeout: u32,
        link_activity_timeout: u32,
    };
    pub const Completion = struct {
        request_id: u64,
        action: Action,
        remote: anyerror!connection.RemoteDescriptor,

        /// Releases a result that was not handed to the connection/looper.
        pub fn deinit(self: Completion) void {
            const remote = self.remote catch return;
            if (remote.link) |link| link.cleanup();
        }
    };
    pub const Callback = struct {
        context: *anyopaque,
        // Ownership of the result and the accepted work's context transfers here.
        call: *const fn (*anyopaque, *anyopaque, Completion) void,
    };
    const Work = struct {
        request: Request,
        completion_context: *anyopaque,
    };
    const Actor = core.actor.Actor(ConnectionWorker, null, Work, error{}, execute);

    allocator: std.mem.Allocator,
    resolver: sandbox.DNSResolver,
    factory: sandbox.SocketFactory,
    endpoint_resolver: ?resolver_mod.EndpointResolver,
    callback: Callback,
    actor: *Actor,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn create(
        allocator: std.mem.Allocator,
        resolver: sandbox.DNSResolver,
        factory: sandbox.SocketFactory,
        endpoints: ?[]const api.ExtendedEndpoint,
        callback: Callback,
    ) error{OutOfMemory}!*ConnectionWorker {
        const self = try allocator.create(ConnectionWorker);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .resolver = resolver,
            .factory = factory,
            .endpoint_resolver = null,
            .callback = callback,
            .actor = undefined,
        };
        // Connection may be released while preparation is still blocked.
        if (endpoints) |source| {
            const owned = try allocator.alloc(api.ExtendedEndpoint, source.len);
            var count: usize = 0;
            errdefer {
                for (owned[0..count]) |*endpoint| endpoint.deinit(allocator);
                allocator.free(owned);
            }
            for (source, owned) |endpoint, *copy| {
                copy.* = try endpoint.clone(allocator);
                count += 1;
            }
            self.endpoint_resolver = resolver_mod.EndpointResolver.init(allocator, owned);
        }
        errdefer self.deinitEndpoints();
        self.actor = Actor.create(allocator, self) catch return error.OutOfMemory;
        return self;
    }

    /// Accepted requests always deliver exactly one completion, including on close.
    pub fn submit(self: *ConnectionWorker, request: Request, completion_context: *anyopaque) error{ Closed, OutOfMemory }!void {
        if (self.closed.load(.acquire)) return error.Closed;
        try self.actor.schedule(.{ .request = request, .completion_context = completion_context });
    }

    /// Rejects new work without waiting for a running DNS/socket call.
    pub fn close(self: *ConnectionWorker) void {
        self.closed.store(true, .release);
    }

    /// Call outside the event loop, while the callback and dependencies remain valid.
    pub fn destroy(self: *ConnectionWorker) void {
        self.close();
        self.actor.destroy();
        self.deinitEndpoints();
        self.allocator.destroy(self);
    }

    fn deinitEndpoints(self: *ConnectionWorker) void {
        if (self.endpoint_resolver) |*resolver| {
            resolver.deinit();
            core.util.freeSlice(api.ExtendedEndpoint, self.allocator, resolver.endpoints);
        }
    }

    fn execute(self: *ConnectionWorker, comptime Result: type, work: Work) error{}!Result {
        const remote = if (self.closed.load(.acquire)) error.Closed else self.prepareLink(work.request);
        self.callback.call(self.callback.context, work.completion_context, .{
            .request_id = work.request.request_id,
            .action = work.request.action,
            .remote = remote,
        });
    }

    fn prepareLink(self: *ConnectionWorker, request: Request) !connection.RemoteDescriptor {
        var remote = connection.RemoteDescriptor{};
        log.write(.notice, "Create new link");
        var endpoint: ?api.ExtendedEndpoint = null;
        if (self.endpoint_resolver) |*resolver| {
            log.write(.notice, "Cycle to next endpoint");
            endpoint = try resolver.next(&self.resolver, request.reachability, request.dns_timeout);
            log.writef(.notice, "Connect to {s}", .{endpoint.?});
        }
        // Do not open a socket after stop if a blocked DNS query has just returned.
        if (self.closed.load(.acquire)) return error.Closed;
        remote.endpoint = if (endpoint) |resolved| try io.SocketEndpoint.init(resolved) else null;
        const unconnected = if (remote.endpoint) |resolved|
            resolved.plainSocketType() == .udp and !request.connect_udp
        else
            true;
        var descriptor = try self.factory.create(
            self.allocator,
            if (unconnected) null else endpoint,
            request.local_port,
            request.reachability,
            request.link_activity_timeout,
        );
        errdefer descriptor.cleanup();
        if (unconnected) remote.local_port = (try descriptor.localAddress()).port;
        remote.link = descriptor;
        return remote;
    }
};
