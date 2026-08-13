// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const conn_mod = @import("connection.zig");
const core = @import("../core/exports.zig");
const io = @import("io.zig");

const api = core.api;
const log = core.logging;
const Connection = conn_mod.Connection;
const ConnectionRegistry = conn_mod.ConnectionRegistry;
const activeConnectionModule = conn_mod.activeConnectionModule;

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

    mutex: core.Mutex = .{},
    reachability_block: ReachabilityBlock,
    on_ready: ?OnReadyBlock = null,
    observing: bool = false,
    state: State = .{
        .enabled = false,
        .network_available = false,
        .connection_status = .disconnected,
    },

    pub fn init(reachability_block: ?ReachabilityBlock) ConnectionGate {
        return .{
            .reachability_block = reachability_block orelse .{
                .is_reachable = neverReachable,
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

    profile_id: ProfileId,
    report_snapshot: ReportBlock,
    report_snapshot_ctx: *const anyopaque,
    min_data_count_delta: u64,
    environment: api.TunnelSnapshotEnvironment = emptyEnvironment(),
    last_published_snapshot: ?api.TunnelSnapshot = null,

    pub fn init(
        profile_id: ProfileId,
        report_snapshot: ReportBlock,
        report_snapshot_ctx: *const anyopaque,
        min_data_count_delta: u64,
    ) SnapshotPublisher {
        return .{
            .profile_id = profile_id,
            .report_snapshot = report_snapshot,
            .report_snapshot_ctx = report_snapshot_ctx,
            .min_data_count_delta = min_data_count_delta,
        };
    }

    pub fn clearEnvironment(self: *SnapshotPublisher) void {
        self.environment = emptyEnvironment();
    }

    pub fn setConnectionStatus(self: *SnapshotPublisher, status: api.ConnectionStatus) void {
        self.environment.connection_status = status;
    }

    pub fn setLastError(self: *SnapshotPublisher, code: ?api.PartoutErrorCode) void {
        self.environment.last_error_code = if (code) |c| c.raw() else null;
    }

    pub fn setDataCount(self: *SnapshotPublisher, data_count: api.DataCount) void {
        self.environment.data_count = data_count;
    }

    pub fn publishCurrentSnapshot(self: *SnapshotPublisher, force: bool) void {
        const snapshot = api.TunnelSnapshot{
            .id = self.profile_id,
            .is_enabled = true,
            .status = tunnelStatus(self.environment.connection_status),
            .on_demand = false,
            .environment = self.environment,
        };
        if (!self.shouldPublishSnapshot(snapshot, force)) return;

        self.last_published_snapshot = snapshot;
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
        return received_delta +| sent_delta;
    }

    fn uintDelta(lhs: u64, rhs: u64) u64 {
        return if (lhs >= rhs) lhs - rhs else rhs - lhs;
    }
};
