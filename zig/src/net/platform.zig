// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const platform_mod = @This();
const c_mod = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const io = @import("io.zig");
const platform_dns = @import("platform_dns.zig");
const sandbox = @import("sandbox.zig");

const api = core.api;
const c = c_mod.io;
const log = core.logging;
const util = core.util;

const DNSResolver = sandbox.DNSResolver;
const PlatformDNS = platform_dns.PlatformDNS;
const ReachabilityInfo = io.ReachabilityInfo;
const NetworkMonitor = sandbox.NetworkMonitor;
const SocketDescriptor = io.SocketDescriptor;
const SocketFactory = sandbox.SocketFactory;
const SocketOptions = io.SocketOptions;
const SocketWrapper = io.SocketWrapper;
const TunnelController = sandbox.TunnelController;
const TunWrapper = io.TunWrapper;

pub const Platform = struct {
    pub const FunctionTable = c.pp_tun_ctrl_fnt;

    pub const EnvironmentValueBlock = struct {
        ptr: ?*anyopaque = null,
        get: *const fn (?*anyopaque, []const u8) ?[]const u8,

        fn call(self: EnvironmentValueBlock, key: []const u8) ?[]const u8 {
            return self.get(self.ptr, key);
        }
    };

    pub const Options = struct {
        /// The optional reference to forward C calls to (e.g. JNI).
        ref: ?*anyopaque = null,

        /// The tunnel controller implementation.
        fnt: ?FunctionTable = null,

        /// Requests a value from the tunnel environment.
        /// ZIGME: Delete this and from pp_tun_ctrl_delegate
        environment_value: ?EnvironmentValueBlock = null,

        /// The socket buffer size.
        socket_buf_size: c_int = 1024 * 1024,
    };

    //#region Input

    ref: ?*anyopaque,
    fnt: FunctionTable,
    dns: PlatformDNS,
    environment_value: ?EnvironmentValueBlock,
    socket_buf_size: c_int,

    //#endregion

    //#region Internal state

    /// Protects access to event handlers from the outside, because
    /// reachability and better path signals may come from any thread.
    callbacksMutex: core.Mutex = .{},
    monitor_drainer: core.Drainer = .{},

    current_reachability: ?ReachabilityInfo = null,
    monitor_event_handler: ?NetworkMonitor.EventHandler = null,
    better_path_count: usize = 0,
    delegate: c.pp_tun_ctrl_delegate = undefined,
    delegate_attached: bool = false,

    //#endregion

    pub fn init(options: Options) error{OutOfMemory}!Platform {
        var ref_copy: ?*anyopaque = null;
        if (builtin.abi.isAndroid() and @hasDecl(c, "pp_jni_new_global_ref")) {
            ref_copy = c.pp_jni_new_global_ref(options.ref);
            if (ref_copy == null) {
                log.write(.fault, "Unable to retain platform JNI ref");
                return error.OutOfMemory;
            }
        } else {
            ref_copy = options.ref;
        }
        return .{
            .ref = ref_copy,
            .fnt = options.fnt orelse c.pp_tun_ctrl_fnt_current(),
            .dns = .{},
            .environment_value = options.environment_value,
            .socket_buf_size = options.socket_buf_size,
        };
    }

    pub fn attach(self: *Platform) void {
        self.delegate = .{
            .ctx = self,
            .on_reachability = cOnReachability,
            .on_better_path = cOnBetterPath,
            .environment_value = cEnvironmentValue,
        };
        if (self.ref) |ref| {
            log.writef(.debug, "Platform: Set delegate ({*})", .{ref});
            self.fnt.set_delegate.?(ref, &self.delegate);
            self.delegate_attached = true;
        }
    }

    pub fn deinit(self: *Platform) void {
        if (self.delegate_attached) {
            log.write(.debug, "Platform: Clear delegate");
            self.fnt.set_delegate.?(self.ref, null);
            self.delegate_attached = false;
        }
        if (builtin.abi.isAndroid() and @hasDecl(c, "pp_jni_delete_global_ref")) {
            c.pp_jni_delete_global_ref(self.ref);
        }
        log.write(.debug, "Deinit Platform");
        self.monitor_drainer.deinit();
        self.callbacksMutex.deinit();
    }

    //#region Implemented interfaces

    pub fn tunnelController(self: *Platform) TunnelController {
        return .{
            .ptr = self,
            .vtable = &platform_tunnel_controller_vtable,
        };
    }

    pub fn dnsResolver(self: *Platform) DNSResolver {
        return self.dns.interface();
    }

    pub fn socketFactory(self: *Platform) SocketFactory {
        return .{
            .ptr = self,
            .vtable = &platform_socket_factory_vtable,
        };
    }

    pub fn networkMonitor(self: *Platform) NetworkMonitor {
        return .{
            .ptr = self,
            .vtable = &platform_network_monitor_vtable,
        };
    }

    //#endregion

    //#region Network events (must serialize)

    pub fn currentReachability(self: *Platform) ?ReachabilityInfo {
        self.callbacksMutex.lock();
        defer self.callbacksMutex.unlock();

        return self.current_reachability;
    }

    fn isReachable(self: *Platform) bool {
        self.callbacksMutex.lock();
        defer self.callbacksMutex.unlock();

        return (self.current_reachability orelse return false).reachable;
    }

    fn setMonitorEventHandler(self: *Platform, handler: ?NetworkMonitor.EventHandler) void {
        self.callbacksMutex.lock();
        defer self.callbacksMutex.unlock();

        self.monitor_event_handler = handler;
        if (handler == null) {
            self.monitor_drainer.drain(&self.callbacksMutex);
        }
    }

    fn betterPathCount(self: *Platform) usize {
        self.callbacksMutex.lock();
        defer self.callbacksMutex.unlock();

        return self.better_path_count;
    }

    fn notifyReachability(self: *Platform, reachability: ReachabilityInfo) void {
        self.callbacksMutex.lock();
        self.current_reachability = reachability;
        const handler = self.monitor_event_handler;
        if (handler != null) {
            self.monitor_drainer.enter();
        }
        self.callbacksMutex.unlock();

        log.write(.debug, "Reachability changed");
        if (handler) |block| {
            defer self.monitor_drainer.leave(&self.callbacksMutex);
            block.onReachability(reachability);
        }
    }

    fn notifyBetterPath(self: *Platform) void {
        self.callbacksMutex.lock();
        self.better_path_count += 1;
        const handler = self.monitor_event_handler;
        if (handler != null) {
            self.monitor_drainer.enter();
        }
        self.callbacksMutex.unlock();

        log.write(.debug, "Network better path available");
        if (handler) |block| {
            defer self.monitor_drainer.leave(&self.callbacksMutex);
            block.onBetterPath();
        }
    }

    //#endregion

    //#region Socket factory

    fn socketOptions(
        self: *Platform,
        endpoint: api.ExtendedEndpoint,
        reachability: ?ReachabilityInfo,
        timeout: c_int,
    ) SocketOptions {
        return .{
            .endpoint = endpoint,
            .timeout_ms = timeout,
            .buf_size = self.socket_buf_size,
            .reachability = reachability,
            .configure = cConfigureSocket,
            .configure_ctx = self,
        };
    }

    // Make sure to use C calling convention as this is passed
    // as a callback to a C function in SocketWrapper
    fn cConfigureSocket(
        ctx: ?*anyopaque,
        descriptor: SocketDescriptor,
        reachability: ?*const ReachabilityInfo,
    ) callconv(.c) bool {
        const self: *Platform = @ptrCast(@alignCast(ctx orelse return true));
        return self.configureSocket(
            descriptor,
            if (reachability) |info| info.* else null,
        );
    }

    fn configureSocket(
        self: *Platform,
        descriptor: SocketDescriptor,
        reachability: ?ReachabilityInfo,
    ) bool {
        self.configureSocketsWithError(&.{descriptor}, reachability) catch |err| {
            log.writef(.fault, "Unable to configure sockets: {}", .{err});
            return false;
        };
        return true;
    }

    //#endregion

    fn configureSocketsWithError(
        self: *Platform,
        descriptors: []const SocketDescriptor,
        reachability: ?ReachabilityInfo,
    ) TunnelController.Error!void {
        if (descriptors.len == 0) return;

        var reachability_copy = reachability;
        const reachability_ptr = if (reachability_copy) |*value| value else null;
        log.writef(.debug, "Configure tunnel sockets: count={}", .{descriptors.len});
        if (!self.fnt.configure_sockets.?(self.ref, reachability_ptr, descriptors.ptr, descriptors.len)) {
            return error.SocketConfiguration;
        }
    }

    //#region Environment

    fn environmentValue(self: *Platform, key: []const u8) ?[]const u8 {
        log.writef(.debug, "Get tunnel environment: {s}", .{key});
        const block = self.environment_value orelse return null;
        return block.call(key);
    }

    //#endregion
};

//#region Tunnel controller

const platform_tunnel_controller_vtable = TunnelController.VTable{
    .set_tunnel_settings = ctrlSetTunnelSettings,
    .configure_sockets = ctrlConfigureSockets,
    .report_snapshot = ctrlReportSnapshot,
    .clear_tunnel_settings = ctrlClearTunnelSettings,
    .set_reasserting = ctrlSetReasserting,
    .cancel_tunnel_connection = ctrlCancelTunnelConnection,
};

fn ctrlSetTunnelSettings(ptr: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) TunnelController.Error!?TunWrapper {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    const allocator = std.heap.c_allocator;

    var c_uuid: util.TemporaryCString = .{};
    try c_uuid.init(allocator, info.original_module_id[0..]);
    defer c_uuid.deinit();
    const c_info = try core.util.encodeJsonValueZ(allocator, info);
    defer allocator.free(c_info);

    log.write(.debug, "Platform: Set tunnel");
    const maybe_tun = self.fnt.set_tunnel.?(self.ref, c_uuid.ptr(), c_info.ptr);
    if (!info.requires_virtual_device) {
        log.write(.debug, "Platform: No virtual device required");
        if (maybe_tun) |tun| {
            // Android retains the descriptor in the VPN service. Other
            // platforms return an independently owned tunnel handle here.
            c.pp_tun_free_and_close(tun, !builtin.abi.isAndroid());
        }
        return null;
    }
    const tun = maybe_tun orelse {
        return error.TunNotAvailable;
    };
    return TunWrapper.init(tun);
}

fn ctrlConfigureSockets(ptr: ?*anyopaque, descriptors: []const SocketDescriptor) TunnelController.Error!void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    return self.configureSocketsWithError(descriptors, self.currentReachability());
}

fn ctrlReportSnapshot(ptr: ?*anyopaque, snapshot: api.TunnelSnapshot) void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    const allocator = std.heap.c_allocator;
    const c_snapshot = core.util.encodeJsonValueZ(allocator, snapshot) catch |err| {
        log.writef(.err, "Unable to encode snapshot: {}", .{err});
        return;
    };
    defer allocator.free(c_snapshot);
    self.fnt.report_snapshot.?(self.ref, c_snapshot.ptr);
}

fn ctrlClearTunnelSettings(ptr: ?*anyopaque, with_kill_switch: bool) void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    log.writef(.debug, "Clear tunnel settings: withKillSwitch={}", .{with_kill_switch});
    self.fnt.clear_tunnel.?(self.ref, with_kill_switch);
}

fn ctrlSetReasserting(_: ?*anyopaque, _: bool) void {}

fn ctrlCancelTunnelConnection(ptr: ?*anyopaque, code: ?api.PartoutErrorCode) void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    const raw_code = if (code) |value| @tagName(value) else null;
    if (raw_code) |value| {
        log.writef(.err, "Cancel tunnel connection: {s}", .{value});
        self.fnt.cancel_tunnel.?(self.ref, value.ptr);
        return;
    }
    log.write(.debug, "Cancel tunnel connection");
    self.fnt.cancel_tunnel.?(self.ref, null);
}

//#endregion

//#region Socket factory

const platform_socket_factory_vtable = SocketFactory.VTable{
    .current_reachability = socketFactoryCurrentReachability,
    .create = socketFactoryCreate,
};

fn socketFactoryCurrentReachability(ptr: ?*anyopaque) ?ReachabilityInfo {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    return self.currentReachability();
}

fn socketFactoryCreate(
    ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    endpoint: api.ExtendedEndpoint,
    reachability: ?ReachabilityInfo,
    timeout: c_int,
) SocketFactory.Error!io.IOInterface {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    const effective_reachability = reachability orelse self.currentReachability();

    // Must return owned variant to outlive method
    const wrapper = try SocketWrapper.create(
        allocator,
        self.socketOptions(endpoint, effective_reachability, timeout),
    ) orelse return error.LinkNotActive;
    log.writef(.debug, "PlatformSocketFactory: Created socket for {s}", .{endpoint.address});
    return wrapper.nativeIO();
}

//#endregion

//#region Network monitor

const platform_network_monitor_vtable = NetworkMonitor.VTable{
    .start_observing = monitorStartObserving,
    .stop_observing = monitorStopObserving,
    .set_event_handler = monitorSetEventHandler,
    .is_reachable = monitorIsReachable,
};

fn monitorStartObserving(_: ?*anyopaque) void {}

fn monitorStopObserving(_: ?*anyopaque) void {}

fn monitorSetEventHandler(ptr: ?*anyopaque, handler: ?NetworkMonitor.EventHandler) void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    self.setMonitorEventHandler(handler);
}

fn monitorIsReachable(ptr: ?*anyopaque) bool {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    return self.isReachable();
}

//#endregion

//#region C callbacks (proxy to native code)

fn cOnReachability(ctx: ?*anyopaque, reachability: [*c]const ReachabilityInfo) callconv(.c) void {
    const self: *Platform = @ptrCast(@alignCast(ctx orelse return));
    if (reachability == null) return;
    self.notifyReachability(reachability.*);
    if (builtin.abi.isAndroid() and @hasField(ReachabilityInfo, "network_handle")) {
        log.writef(.debug, "Network reachability changed: reachable={}, network_handle={}", .{
            reachability[0].reachable,
            reachability[0].network_handle,
        });
    } else {
        log.writef(.debug, "Network reachability changed: reachable={}", .{reachability[0].reachable});
    }
}

fn cOnBetterPath(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Platform = @ptrCast(@alignCast(ctx orelse return));
    self.notifyBetterPath();
}

fn cEnvironmentValue(ctx: ?*anyopaque, key: [*c]const u8) callconv(.c) [*c]u8 {
    const self: *Platform = @ptrCast(@alignCast(ctx orelse return null));
    if (key == null) return null;
    const key_z: [*:0]const u8 = @ptrCast(key);
    const value = self.environmentValue(std.mem.span(key_z)) orelse return null;
    const c_value = std.heap.c_allocator.dupeSentinel(u8, value, 0) catch return null;
    return c_value.ptr;
}

//#endregion

pub const testing = struct {
    pub const platformConfigureSocket = platform_mod.Platform.cConfigureSocket;

    pub fn socketOptions(
        platform: *Platform,
        endpoint: api.ExtendedEndpoint,
        reachability: ?ReachabilityInfo,
        timeout: c_int,
    ) SocketOptions {
        return platform.socketOptions(endpoint, reachability, timeout);
    }

    pub fn betterPathCount(platform: *Platform) usize {
        return platform.betterPathCount();
    }

    pub fn notifyReachability(platform: *Platform, reachability: ReachabilityInfo) void {
        platform.notifyReachability(reachability);
    }

    pub fn notifyBetterPath(platform: *Platform) void {
        platform.notifyBetterPath();
    }
};
