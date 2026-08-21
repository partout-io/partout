// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const builtin = @import("builtin");

const platform_mod = @This();
const c_mod = @import("../c/exports.zig");
const core = @import("../core/exports.zig");
const io = @import("io.zig");
const looper = @import("looper.zig");
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

    fn validateFunctionTable(fnt: FunctionTable) void {
        inline for (@typeInfo(FunctionTable).@"struct".fields) |field| {
            if (@field(fnt, field.name) == null) {
                @panic("Platform function table has no " ++ field.name ++ " callback");
            }
        }
    }

    pub const Options = struct {
        /// The optional reference to forward C calls to (e.g. JNI).
        ref: ?*anyopaque = null,

        /// The tunnel controller implementation.
        fnt: ?FunctionTable = null,

        /// The socket buffer size.
        socket_buf_size: c_int = 1024 * 1024,
    };

    //#region Input

    ref: ?*anyopaque,
    fnt: FunctionTable,
    dns: PlatformDNS,
    socket_buf_size: c_int,

    //#endregion

    //#region Internal state

    /// Protects access to event handlers from the outside, because
    /// reachability and better path signals may come from any thread.
    callbacksMutex: core.Mutex,
    monitor_drainer: core.Drainer,

    current_reachability: ?ReachabilityInfo,
    monitor_event_handler: ?NetworkMonitor.EventHandler,
    better_path_count: usize,
    delegate: c.pp_tun_ctrl_delegate,
    delegate_attached: bool,

    //#endregion

    pub fn init(options: Options) error{OutOfMemory}!Platform {
        const functions = options.fnt orelse c.pp_tun_ctrl_fnt_current();
        validateFunctionTable(functions);
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
            .fnt = functions,
            .dns = .{},
            .socket_buf_size = options.socket_buf_size,
            .callbacksMutex = .{},
            .monitor_drainer = .{},
            .current_reachability = null,
            .monitor_event_handler = null,
            .better_path_count = 0,
            .delegate = undefined,
            .delegate_attached = false,
        };
    }

    pub fn attach(self: *Platform) void {
        self.delegate = .{
            .ctx = self,
            .on_reachability = cOnReachability,
            .on_better_path = cOnBetterPath,
        };
        if (self.ref) |ref| {
            log.writef(.debug, "Platform: Set delegate ({*})", .{ref});
            const set_delegate = self.fnt.set_delegate orelse
                @panic("Platform function table has no set_delegate callback");
            set_delegate(ref, &self.delegate);
            self.delegate_attached = true;
        }
    }

    pub fn deinit(self: *Platform) void {
        if (self.delegate_attached) {
            log.write(.debug, "Platform: Clear delegate");
            const set_delegate = self.fnt.set_delegate orelse
                @panic("Platform function table has no set_delegate callback");
            set_delegate(self.ref, null);
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
        self: *const Platform,
        descriptor: SocketDescriptor,
        reachability: ?ReachabilityInfo,
    ) bool {
        self.configureSocketsWithError(&.{descriptor}, reachability) catch |err| {
            log.writef(.fault, "Unable to configure sockets: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    //#endregion

    fn configureSocketsWithError(
        self: *const Platform,
        descriptors: []const SocketDescriptor,
        reachability: ?ReachabilityInfo,
    ) TunnelController.Error!void {
        if (descriptors.len == 0) return;

        var reachability_copy = reachability;
        const reachability_ptr = if (reachability_copy) |*value| value else null;
        log.writef(.debug, "Configure tunnel sockets: count={}", .{descriptors.len});
        const configure_sockets = self.fnt.configure_sockets orelse
            @panic("Platform function table has no configure_sockets callback");
        if (!configure_sockets(self.ref, reachability_ptr, descriptors.ptr, descriptors.len)) {
            return error.SocketConfiguration;
        }
    }
};

//#region Tunnel controller

const platform_tunnel_controller_vtable = TunnelController.VTable{
    .set_tunnel_settings = ctrlSetTunnelSettings,
    .configure_sockets = ctrlConfigureSockets,
    .report_snapshot = ctrlReportSnapshot,
    .set_environment_value = ctrlSetEnvironmentValue,
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
    const set_tunnel = self.fnt.set_tunnel orelse
        @panic("Platform function table has no set_tunnel callback");
    const maybe_tun = set_tunnel(self.ref, c_uuid.ptr(), c_info.ptr);
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
        log.writef(.err, "Unable to encode snapshot: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(c_snapshot);
    const report_snapshot = self.fnt.report_snapshot orelse
        @panic("Platform function table has no report_snapshot callback");
    report_snapshot(self.ref, c_snapshot.ptr);
}

fn ctrlSetEnvironmentValue(ptr: ?*anyopaque, key: []const u8, value: ?[]const u8) void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    const allocator = std.heap.c_allocator;

    var c_key: util.TemporaryCString = .{};
    c_key.init(allocator, key) catch {
        log.write(.err, "Unable to encode environment key");
        return;
    };
    defer c_key.deinit();
    const set_environment_value = self.fnt.set_environment_value orelse
        @panic("Platform function table has no set_environment_value callback");

    if (value) |raw_value| {
        var c_value: util.TemporaryCString = .{};
        c_value.init(allocator, raw_value) catch {
            log.write(.err, "Unable to encode environment value");
            return;
        };
        defer c_value.deinit();
        set_environment_value(self.ref, c_key.ptr(), c_value.ptr());
    } else {
        set_environment_value(self.ref, c_key.ptr(), null);
    }
}

fn ctrlClearTunnelSettings(ptr: ?*anyopaque, with_kill_switch: bool) void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    log.writef(.debug, "Clear tunnel settings: withKillSwitch={}", .{with_kill_switch});
    const clear_tunnel = self.fnt.clear_tunnel orelse
        @panic("Platform function table has no clear_tunnel callback");
    clear_tunnel(self.ref, with_kill_switch);
}

fn ctrlSetReasserting(_: ?*anyopaque, _: bool) void {}

fn ctrlCancelTunnelConnection(ptr: ?*anyopaque, code: ?api.PartoutErrorCode) void {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    const cancel_tunnel = self.fnt.cancel_tunnel orelse
        @panic("Platform function table has no cancel_tunnel callback");
    const raw_code = if (code) |value| @tagName(value) else null;
    if (raw_code) |value| {
        log.writef(.err, "Cancel tunnel connection: {s}", .{value});
        cancel_tunnel(self.ref, value.ptr);
        return;
    }
    log.write(.debug, "Cancel tunnel connection");
    cancel_tunnel(self.ref, null);
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
) SocketFactory.Error!looper.Looper.Descriptor {
    const self: *Platform = @ptrCast(@alignCast(ptr.?));
    const effective_reachability = reachability orelse self.currentReachability();

    // Must return owned variant to outlive method
    const wrapper = try SocketWrapper.create(
        allocator,
        self.socketOptions(endpoint, effective_reachability, timeout),
    ) orelse return error.LinkNotActive;
    log.writef(.debug, "PlatformSocketFactory: Created socket for {s}", .{
        log.sensitive(endpoint.address),
    });
    const fd = wrapper.muxDescriptor() orelse {
        wrapper.nativeIO().cleanup();
        return error.LinkNotActive;
    };
    return .{
        .fd = fd,
        .io = wrapper.nativeIO(),
    };
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
