// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const core = @import("../core/exports.zig");
const connection = @import("connection.zig");
const io = @import("io.zig");
const resolver_mod = @import("resolver.zig");
const sandbox = @import("sandbox.zig");
const windows = @import("connection_worker_windows.zig");

const api = core.api;
const log = core.logging;

/// Serial link preparation, independent of Connection and its event loop.
/// Owns endpoint storage and DNS state until destroy() drains preparation.
pub const ConnectionWorker = struct {
    const Self = @This();
    pub const Action = enum { start, rebind };
    pub const Request = struct {
        request_id: u64,
        action: Action,
        local_port: u16,
        reachability: ?io.ReachabilityInfo,
        connect_udp: bool,
        dns_timeout: u32,
        link_activity_timeout: u32,
        /// Owned by the request until delivery, then by the completion receiver.
        tun_info: ?api.TunnelRemoteInfoWrapper = null,
    };
    pub const Completion = struct {
        request_id: u64,
        action: Action,
        remote: anyerror!connection.RemoteDescriptor,
        /// Owned by the completion receiver.
        tun_info: ?api.TunnelRemoteInfoWrapper = null,

        /// Releases a link that was not handed to the connection/looper.
        /// The receiver releases tun_info separately, including after successful handoff.
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
    const Executor = if (builtin.os.tag == .windows and build_options.winrt)
        windows.Executor(Self, Work, execute)
    else
        core.actor.Actor(Self, null, Work, error{}, execute);

    allocator: std.mem.Allocator,
    resolver: sandbox.DNSResolver,
    factory: sandbox.SocketFactory,
    endpoint_resolver: ?resolver_mod.EndpointResolver,
    callback: Callback,
    executor: *Executor,
    closed: std.atomic.Value(bool) = .init(false),

    pub fn create(
        allocator: std.mem.Allocator,
        resolver: sandbox.DNSResolver,
        factory: sandbox.SocketFactory,
        endpoints: ?[]const api.ExtendedEndpoint,
        callback: Callback,
    ) error{OutOfMemory}!*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .resolver = resolver,
            .factory = factory,
            .endpoint_resolver = null,
            .callback = callback,
            .executor = undefined,
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
        self.executor = Executor.create(allocator, self) catch return error.OutOfMemory;
        return self;
    }

    /// Accepted requests always deliver exactly one completion, including on close.
    pub fn submit(self: *Self, request: Request, completion_context: *anyopaque) error{ Closed, OutOfMemory }!void {
        if (self.closed.load(.acquire)) return error.Closed;
        try self.executor.schedule(.{ .request = request, .completion_context = completion_context });
    }

    /// Rejects new work without waiting for a running DNS/socket call.
    pub fn close(self: *Self) void {
        self.closed.store(true, .release);
    }

    /// Call outside the event loop, while the callback and dependencies remain valid.
    pub fn destroy(self: *Self) void {
        self.close();
        self.executor.destroy();
        self.deinitEndpoints();
        self.allocator.destroy(self);
    }

    fn deinitEndpoints(self: *Self) void {
        if (self.endpoint_resolver) |*resolver| {
            resolver.deinit();
            core.util.freeSlice(api.ExtendedEndpoint, self.allocator, resolver.endpoints);
        }
    }

    fn execute(self: *Self, comptime Result: type, work: Work) error{}!Result {
        const remote = if (self.closed.load(.acquire)) error.Closed else self.prepareLink(work.request);
        self.callback.call(self.callback.context, work.completion_context, .{
            .request_id = work.request.request_id,
            .action = work.request.action,
            .remote = remote,
            .tun_info = work.request.tun_info,
        });
    }

    fn prepareLink(self: *Self, request: Request) !connection.RemoteDescriptor {
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
