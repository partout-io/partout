// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const abi_runtime = @import("../abi/runtime.zig");
const core = @import("../core/exports.zig");
const helpers = @import("../abi/helpers.zig");
const net = @import("../net/exports.zig");
const net_conn = @import("../net/connection.zig");
const net_daemon = @import("../net/daemon.zig");
const net_io = @import("../net/io.zig");
const net_sandbox = @import("../net/sandbox.zig");

const api = core.api;
const util = core.util;

// ZIGME: Hardcode until only Zig ABI
pub export fn partout_log(_: i32, message: [*:0]const u8) void {
    std.debug.print("{s}\n", .{message});
}

pub const MockRuntime = struct {
    current: ?Instance = null,

    pub const noop_completion = helpers.Completion{
        .callback = null,
        .ctx = null,
    };

    const Instance = struct {
        daemon: *net_daemon.Daemon,
        bindings: ?helpers.CDaemonBindings,
        runtime: *MockDaemonRuntime,

        fn finishTeardown(self: *Instance, allocator: std.mem.Allocator) void {
            self.daemon.deinit(allocator);
            allocator.destroy(self.daemon);
            self.runtime.deinit(allocator);
            if (self.bindings) |*bindings| {
                if (bindings.release) |release| {
                    release(bindings);
                }
            }
        }
    };

    pub fn start(self: *MockRuntime, allocator: std.mem.Allocator, args: helpers.CDaemonStartArgs) abi_runtime.StartError!void {
        if (self.current != null) return error.AlreadyStarted;

        const c_profile = args.profile orelse return error.InvalidArgs;

        const profile_json = util.cString(c_profile);

        const runtime = try MockDaemonRuntime.create(allocator, args);
        errdefer runtime.deinit(allocator);

        var profile = api.Profile.parse(allocator, profile_json) catch |profile_err| {
            return switch (profile_err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidProfile,
            };
        };
        errdefer profile.deinit(allocator);

        const new_daemon = net_daemon.Daemon.create(allocator, profile, .{
            .objects = .{
                .registry = runtime.connectionRegistry(),
                .controller = runtime.tunnelController(),
                .resolver = runtime.dnsResolver(),
                .factory = runtime.socketFactory(),
                .monitor = runtime.networkMonitor(),
            },
            .options = .{
                .starts_immediately = false,
                .cancels_unrecoverable = true,
                .stop_delay_ms = 2000,
                .reconnection_delay_ms = 2000,
                .min_data_count_delta = args.options.min_data_count_delta,
                .events = runtime.daemonEvents(),
            },
        }) catch |err| {
            return switch (err) {
                error.InvalidJson, error.InvalidModel, error.UnsupportedModel => error.InvalidProfile,
                error.AlreadyStarted => error.AlreadyStarted,
                error.Closed => error.Closed,
                error.MissingConnectionImplementation => error.MissingConnectionImplementation,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        errdefer new_daemon.deinit(allocator);

        new_daemon.start(allocator) catch {
            return error.InvalidProfile;
        };

        self.current = .{
            .daemon = new_daemon,
            .bindings = if (args.bindings) |bindings| bindings.* else null,
            .runtime = runtime,
        };
    }

    pub fn stop(self: *MockRuntime, allocator: std.mem.Allocator) bool {
        const instance = self.current orelse {
            return false;
        };
        self.current = null;

        var stopped = instance;
        stopped.daemon.stop();
        stopped.finishTeardown(allocator);
        return true;
    }

    pub fn isStarted(self: *MockRuntime) bool {
        return self.current != null;
    }

    pub fn currentSetTunnelSettingsCount(self: *MockRuntime) ?usize {
        const instance = self.current orelse return null;
        return instance.runtime.controller.set_tunnel_settings_count;
    }

    pub fn currentStatuses(self: *MockRuntime) ?[]const api.ConnectionStatus {
        const instance = self.current orelse return null;
        return instance.daemon.testStatuses();
    }
};

pub const MockDaemonRuntime = struct {
    openvpn_connection: NoopConnectionImplementation = .{ .module_type = .OpenVPN },
    wireguard_connection: NoopConnectionImplementation = .{ .module_type = .WireGuard },
    registry: net_conn.ConnectionRegistry = undefined,
    controller: MockTunnelController = .{},
    events: ConnectionEventRecorder = .{},
    monitor: MockNetworkMonitor = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        _: helpers.CDaemonStartArgs,
    ) error{OutOfMemory}!*MockDaemonRuntime {
        const self = try allocator.create(MockDaemonRuntime);
        errdefer allocator.destroy(self);

        self.controller = .{};
        self.events = .{};
        self.monitor = .{};
        self.openvpn_connection = NoopConnectionImplementation.withFactory(
            .OpenVPN,
            null,
            mockTunnelConnectionCreate,
        );
        self.wireguard_connection = NoopConnectionImplementation.withFactory(
            .WireGuard,
            null,
            mockTunnelConnectionCreate,
        );

        const connection_implementations = [_]net_conn.ConnectionImplementation{
            self.openvpn_connection.connectionImplementation(),
            self.wireguard_connection.connectionImplementation(),
        };
        self.registry = try net_conn.ConnectionRegistry.init(allocator, &connection_implementations);
        return self;
    }

    pub fn deinit(self: *MockDaemonRuntime, allocator: std.mem.Allocator) void {
        self.registry.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn connectionRegistry(self: *const MockDaemonRuntime) *const net_conn.ConnectionRegistry {
        return &self.registry;
    }

    pub fn tunnelController(self: *MockDaemonRuntime) net.TunnelController {
        return self.controller.interface();
    }

    pub fn dnsResolver(_: *MockDaemonRuntime) net.DNSResolver {
        return noopDNSResolver();
    }

    pub fn socketFactory(_: *MockDaemonRuntime) net.SocketFactory {
        return noopSocketFactory();
    }

    pub fn networkMonitor(self: *MockDaemonRuntime) net.NetworkMonitor {
        return self.monitor.interface();
    }

    pub fn daemonEvents(self: *MockDaemonRuntime) ?net_conn.Connection.Events {
        return self.events.events();
    }

    pub fn context(self: *MockDaemonRuntime, registry: *const net_conn.ConnectionRegistry) net_daemon.Context {
        return .{
            .objects = .{
                .registry = registry,
                .controller = self.controller.interface(),
                .resolver = noopDNSResolver(),
                .factory = noopSocketFactory(),
                .monitor = self.monitor.interface(),
            },
            .options = .{ .events = self.events.events() },
        };
    }
};

pub const NoopModuleImplementation = struct {
    module_type: api.ModuleType,

    pub fn init(module_type: api.ModuleType) NoopModuleImplementation {
        return .{ .module_type = module_type };
    }

    pub fn moduleImplementation(self: *NoopModuleImplementation) core.ModuleImplementation {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn moduleType(ptr: ?*anyopaque) api.ModuleType {
        const self: *NoopModuleImplementation = @ptrCast(@alignCast(ptr.?));
        return self.module_type;
    }

    const vtable = core.ModuleImplementation.VTable{
        .module_type = moduleType,
    };
};

pub const NoopConnectionImplementation = struct {
    module_type: api.ModuleType,
    create_connection_ctx: ?*anyopaque = null,
    create_connection: ?net_conn.ConnectionImplementation.Factory = null,

    pub fn init(module_type: api.ModuleType) NoopConnectionImplementation {
        return .{ .module_type = module_type };
    }

    pub fn withFactory(
        module_type: api.ModuleType,
        create_connection_ctx: ?*anyopaque,
        create_connection: net_conn.ConnectionImplementation.Factory,
    ) NoopConnectionImplementation {
        return .{
            .module_type = module_type,
            .create_connection_ctx = create_connection_ctx,
            .create_connection = create_connection,
        };
    }

    pub fn connectionImplementation(self: *NoopConnectionImplementation) net_conn.ConnectionImplementation {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn moduleType(ptr: ?*anyopaque) api.ModuleType {
        const self: *NoopConnectionImplementation = @ptrCast(@alignCast(ptr.?));
        return self.module_type;
    }

    fn createConnection(
        ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        module: net_conn.ConnectionModule,
        sandbox: net_sandbox.Sandbox,
    ) net_conn.CreateError!net_conn.Connection {
        const self: *NoopConnectionImplementation = @ptrCast(@alignCast(ptr.?));
        if (module.typeOf() != self.module_type) return error.UnexpectedModuleType;
        const factory = self.create_connection orelse return error.MissingConnectionImplementation;
        return factory(self.create_connection_ctx, allocator, module, sandbox);
    }

    const vtable = net_conn.ConnectionImplementation.VTable{
        .module_type = moduleType,
        .create_connection = createConnection,
    };
};

pub fn noopTunnelController() net.TunnelController {
    return .{ .vtable = &noop_controller_vtable };
}

pub fn alwaysReachableMonitor() net.NetworkMonitor {
    return .{ .vtable = &always_reachable_vtable };
}

pub fn noopDNSResolver() net.DNSResolver {
    return .{
        .resolve_block = noop_resolver_block,
    };
}

fn noop_resolver_block(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.EnumSet(net.DNSResolver.Flag),
    _: ?net_io.ReachabilityInfo,
    _: u32,
) net.DNSResolver.Error![]net_sandbox.DNSRecord {
    return allocator.alloc(net_sandbox.DNSRecord, 0);
}

pub fn noopSocketFactory() net.SocketFactory {
    return .{ .vtable = &noop_socket_factory_vtable };
}

const noop_socket_factory_vtable = net.SocketFactory.VTable{
    .current_reachability = noopSocketFactoryCurrentReachability,
    .create = noopSocketFactoryCreate,
};

fn noopSocketFactoryCurrentReachability(_: ?*anyopaque) ?net_io.ReachabilityInfo {
    return null;
}

fn noopSocketFactoryCreate(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: api.ExtendedEndpoint,
    _: ?net_io.ReachabilityInfo,
    _: c_int,
) net.SocketFactory.Error!net_io.IOInterface {
    return error.LinkNotActive;
}

const noop_controller_vtable = net.TunnelController.VTable{
    .set_tunnel_settings = noopSetTunnelSettings,
    .configure_sockets = noopConfigureSockets,
    .report_snapshot = noopReportSnapshot,
    .clear_tunnel_settings = noopClearTunnelSettings,
    .set_reasserting = noopSetReasserting,
    .cancel_tunnel_connection = noopCancelTunnelConnection,
};

fn noopSetTunnelSettings(_: ?*anyopaque, _: api.TunnelRemoteInfoWrapper) net.TunnelController.Error!?net_io.TunWrapper {
    return null;
}

fn noopConfigureSockets(_: ?*anyopaque, _: []const net_io.SocketDescriptor) net.TunnelController.Error!void {}

fn noopReportSnapshot(_: ?*anyopaque, _: api.TunnelSnapshot) void {}

fn noopClearTunnelSettings(_: ?*anyopaque, _: bool) void {}

fn noopSetReasserting(_: ?*anyopaque, _: bool) void {}

fn noopCancelTunnelConnection(_: ?*anyopaque, _: ?api.PartoutErrorCode) void {}

pub const ConnectionEventRecorder = struct {
    connection_status: ?api.ConnectionStatus = null,
    statuses: [16]api.ConnectionStatus = undefined,
    status_count: usize = 0,
    has_data_count: bool = false,
    data_count: api.DataCount = .{},
    last_error_code: ?api.PartoutErrorCode = null,
    remove_count: usize = 0,

    pub fn events(self: *ConnectionEventRecorder) net_conn.Connection.Events {
        return .{
            .ctx = self,
            .status = recordConnectionStatus,
            .last_error = recordLastErrorCode,
            .data_count = recordDataCount,
            .remove_key = recordRemove,
        };
    }

    pub fn statusHistory(self: *const ConnectionEventRecorder) []const api.ConnectionStatus {
        return self.statuses[0..self.status_count];
    }
};

fn recordConnectionStatus(ptr: *anyopaque, status: api.ConnectionStatus) void {
    const self: *ConnectionEventRecorder = @ptrCast(@alignCast(ptr));
    self.connection_status = status;
    if (self.status_count < self.statuses.len) {
        self.statuses[self.status_count] = status;
        self.status_count += 1;
    }
}

fn recordDataCount(ptr: *anyopaque, data_count: api.DataCount) void {
    const self: *ConnectionEventRecorder = @ptrCast(@alignCast(ptr));
    self.has_data_count = true;
    self.data_count = data_count;
}

fn recordLastErrorCode(ptr: *anyopaque, code: api.PartoutErrorCode) void {
    const self: *ConnectionEventRecorder = @ptrCast(@alignCast(ptr));
    self.last_error_code = code;
}

fn recordRemove(ptr: *anyopaque, key: net_conn.Connection.EventKey) void {
    const self: *ConnectionEventRecorder = @ptrCast(@alignCast(ptr));
    self.remove_count += 1;
    switch (key) {
        .connection_status => self.connection_status = null,
        .data_count => {
            self.has_data_count = false;
            self.data_count = .{};
        },
        .last_error_code => self.last_error_code = null,
    }
}

pub fn resetConnectionEventRecorder(self: *ConnectionEventRecorder) void {
    self.connection_status = null;
    self.status_count = 0;
    self.has_data_count = false;
    self.data_count = .{};
    self.last_error_code = null;
    self.remove_count = 0;
}

const always_reachable_vtable = net.NetworkMonitor.VTable{
    .start_observing = noopStartObserving,
    .stop_observing = noopStopObserving,
    .set_event_handler = noopSetEventHandler,
    .is_reachable = alwaysReachable,
};

fn noopStartObserving(_: ?*anyopaque) void {}

fn noopStopObserving(_: ?*anyopaque) void {}

fn noopSetEventHandler(_: ?*anyopaque, _: ?net.NetworkMonitor.EventHandler) void {}

fn alwaysReachable(_: ?*anyopaque) bool {
    return true;
}

const MockConnection = struct {
    controller: net.TunnelController,
    module_id: api.UUID,
    module_type: api.ModuleType,
    tunnel_info: api.TunnelRemoteInfoWrapper,

    fn create(
        allocator: std.mem.Allocator,
        module: net_conn.ConnectionModule,
        parameters: net_sandbox.Sandbox,
    ) net_conn.CreateError!net_conn.Connection {
        const created = try allocator.create(MockConnection);
        errdefer allocator.destroy(created);

        var tunnel_info = try buildTunnelInfo(allocator, parameters.profile.*, module);
        errdefer tunnel_info.deinit(allocator);

        created.* = .{
            .controller = parameters.controller,
            .module_id = module.id(),
            .module_type = module.typeOf(),
            .tunnel_info = tunnel_info,
        };
        return created.asConnection();
    }

    fn asConnection(self: *MockConnection) net_conn.Connection {
        return .{
            .ptr = self,
            .vtable = &mock_connection_vtable,
        };
    }
};

const mock_connection_vtable = net_conn.Connection.VTable{
    .start = start,
    .stop = stop,
    .network_change = networkChange,
    .better_path = betterPath,
    .deinit = deinit,
};

fn mockTunnelConnectionCreate(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: net_conn.ConnectionModule,
    sandbox: net_sandbox.Sandbox,
) net_conn.CreateError!net_conn.Connection {
    return MockConnection.create(allocator, module, sandbox);
}

fn start(ptr: *anyopaque, events: net_conn.Connection.Events) net_conn.StartError!bool {
    const self: *MockConnection = @ptrCast(@alignCast(ptr));
    events.status(events.ctx, .connecting);
    _ = try self.controller.setTunnelSettings(self.tunnel_info);
    events.status(events.ctx, .connected);
    return true;
}

fn stop(
    ptr: *anyopaque,
    _: u32,
    events: net_conn.Connection.Events,
) void {
    const self: *MockConnection = @ptrCast(@alignCast(ptr));
    events.status(events.ctx, .disconnecting);
    self.controller.clearTunnelSettings(false);
    events.status(events.ctx, .disconnected);
}

fn networkChange(_: *anyopaque, _: net_io.ReachabilityInfo, _: net_conn.Connection.Events) void {}

fn betterPath(_: *anyopaque, _: net_conn.Connection.Events) void {}

fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *MockConnection = @ptrCast(@alignCast(ptr));
    self.tunnel_info.deinit(allocator);
    allocator.destroy(self);
}

fn buildTunnelInfo(
    allocator: std.mem.Allocator,
    profile: api.Profile,
    conn_module: net_conn.ConnectionModule,
) net_conn.CreateError!api.TunnelRemoteInfoWrapper {
    const modules = [_]api.TaggedModule{conn_module.module.*};
    const info = api.TunnelRemoteInfoWrapper{
        .profile = profile,
        .original_module_id = conn_module.id(),
        .requires_virtual_device = true,
        .modules = &modules,
    };
    return try info.clone(allocator);
}

fn moduleTypeName(module_type: api.ModuleType) []const u8 {
    return switch (module_type) {
        .OpenVPN => "OpenVPN",
        .WireGuard => "WireGuard",
        else => "unknown",
    };
}

fn snapshotTunnelSettings(info: api.TunnelRemoteInfoWrapper) MockTunnelController.LastTunnelSettings {
    var snapshot = MockTunnelController.LastTunnelSettings{
        .requires_virtual_device = info.requires_virtual_device,
        .original_module_id = info.original_module_id,
        .module_count = if (info.modules) |modules| modules.len else 0,
    };
    const modules = info.modules orelse return snapshot;
    for (modules) |module| {
        switch (module) {
            .DNS => |dns| {
                snapshot.has_dns_module = true;
                snapshot.dns_server_count = dns.servers.len;
                const count = @min(dns.servers.len, snapshot.dns_servers.len);
                for (dns.servers[0..count], 0..) |server, index| {
                    copyFixedString(&snapshot.dns_servers[index], &snapshot.dns_server_lens[index], server.raw);
                }
            },
            else => {},
        }
    }
    return snapshot;
}

fn copyFixedString(buffer: *[64]u8, len: *usize, value: []const u8) void {
    len.* = @min(buffer.len, value.len);
    @memcpy(buffer[0..len.*], value[0..len.*]);
}

pub const MockTunnelController = struct {
    pub const LastTunnelSettings = struct {
        requires_virtual_device: bool,
        original_module_id: api.UUID,
        module_count: usize,
        has_dns_module: bool = false,
        dns_server_count: usize = 0,
        dns_server_lens: [4]usize = .{0} ** 4,
        dns_servers: [4][64]u8 = undefined,

        pub fn dnsServer(self: *const LastTunnelSettings, index: usize) []const u8 {
            return self.dns_servers[index][0..self.dns_server_lens[index]];
        }
    };

    set_tunnel_settings_count: usize = 0,
    clear_tunnel_settings_count: usize = 0,
    configure_sockets_count: usize = 0,
    report_snapshot_count: usize = 0,
    last_settings_info: ?api.TunnelRemoteInfoWrapper = null,
    last_settings: ?LastTunnelSettings = null,
    reasserting: bool = false,
    cancel_count: usize = 0,
    last_cancel_code: ?api.PartoutErrorCode = null,

    pub fn interface(self: *MockTunnelController) net.TunnelController {
        return .{
            .ptr = self,
            .vtable = &mock_controller_vtable,
        };
    }
};

const mock_controller_vtable = net.TunnelController.VTable{
    .set_tunnel_settings = mockSetTunnelSettings,
    .configure_sockets = mockConfigureSockets,
    .report_snapshot = mockReportSnapshot,
    .clear_tunnel_settings = mockClearTunnelSettings,
    .set_reasserting = mockSetReasserting,
    .cancel_tunnel_connection = mockCancelTunnelConnection,
};

fn mockSetTunnelSettings(ptr: ?*anyopaque, info: api.TunnelRemoteInfoWrapper) net.TunnelController.Error!?net_io.TunWrapper {
    const self: *MockTunnelController = @ptrCast(@alignCast(ptr.?));
    self.set_tunnel_settings_count += 1;
    self.last_settings_info = info;
    self.last_settings = snapshotTunnelSettings(info);
    return null;
}

fn mockConfigureSockets(ptr: ?*anyopaque, descriptors: []const net_io.SocketDescriptor) net.TunnelController.Error!void {
    const self: *MockTunnelController = @ptrCast(@alignCast(ptr.?));
    self.configure_sockets_count += 1;
    _ = descriptors;
}

fn mockReportSnapshot(ptr: ?*anyopaque, snapshot: api.TunnelSnapshot) void {
    const self: *MockTunnelController = @ptrCast(@alignCast(ptr.?));
    self.report_snapshot_count += 1;
    _ = snapshot;
}

fn mockClearTunnelSettings(ptr: ?*anyopaque, with_kill_switch: bool) void {
    const self: *MockTunnelController = @ptrCast(@alignCast(ptr.?));
    self.clear_tunnel_settings_count += 1;
    self.last_settings_info = null;
    self.last_settings = null;
    _ = with_kill_switch;
}

fn mockSetReasserting(ptr: ?*anyopaque, reasserting: bool) void {
    const self: *MockTunnelController = @ptrCast(@alignCast(ptr.?));
    self.reasserting = reasserting;
}

fn mockCancelTunnelConnection(ptr: ?*anyopaque, code: ?api.PartoutErrorCode) void {
    const self: *MockTunnelController = @ptrCast(@alignCast(ptr.?));
    self.cancel_count += 1;
    self.last_cancel_code = code;
}

pub const MockNetworkMonitor = struct {
    reachable: bool = true,
    start_count: usize = 0,
    stop_count: usize = 0,
    event_handler: ?net.NetworkMonitor.EventHandler = null,

    pub fn interface(self: *MockNetworkMonitor) net.NetworkMonitor {
        return .{
            .ptr = self,
            .vtable = &mock_monitor_vtable,
        };
    }

    pub fn setReachable(self: *MockNetworkMonitor, reachable: bool) void {
        var info = std.mem.zeroes(net_io.ReachabilityInfo);
        info.reachable = reachable;
        self.onReachability(info);
    }

    pub fn onReachability(self: *MockNetworkMonitor, reachability: net_io.ReachabilityInfo) void {
        self.reachable = reachability.reachable;
        if (self.event_handler) |handler| {
            handler.onReachability(reachability);
        }
    }

    pub fn onBetterPath(self: *MockNetworkMonitor) void {
        if (self.event_handler) |handler| {
            handler.onBetterPath();
        }
    }
};

const mock_monitor_vtable = net.NetworkMonitor.VTable{
    .start_observing = mockStartObserving,
    .stop_observing = mockStopObserving,
    .set_event_handler = mockSetMonitorEventHandler,
    .is_reachable = mockIsReachable,
};

fn mockStartObserving(ptr: ?*anyopaque) void {
    const self: *MockNetworkMonitor = @ptrCast(@alignCast(ptr.?));
    self.start_count += 1;
}

fn mockStopObserving(ptr: ?*anyopaque) void {
    const self: *MockNetworkMonitor = @ptrCast(@alignCast(ptr.?));
    self.stop_count += 1;
}

fn mockSetMonitorEventHandler(ptr: ?*anyopaque, handler: ?net.NetworkMonitor.EventHandler) void {
    const self: *MockNetworkMonitor = @ptrCast(@alignCast(ptr.?));
    self.event_handler = handler;
}

fn mockIsReachable(ptr: ?*anyopaque) bool {
    const self: *MockNetworkMonitor = @ptrCast(@alignCast(ptr.?));
    return self.reachable;
}

const DaemonMockConnection = struct {
    timeout_ms: u32 = 0,

    fn asConnection(self: *DaemonMockConnection) net_conn.Connection {
        return .{
            .ptr = self,
            .vtable = &daemon_mock_connection_vtable,
        };
    }
};

const daemon_mock_connection_vtable = net_conn.Connection.VTable{
    .start = daemonMockStart,
    .stop = daemonMockStop,
    .network_change = daemonMockNetworkChange,
    .better_path = daemonMockBetterPath,
    .deinit = daemonMockDeinit,
};

fn daemonMockStart(_: *anyopaque, events: net_conn.Connection.Events) net_conn.StartError!bool {
    events.status(events.ctx, .connecting);
    events.data_count(events.ctx, .{ .received = 10, .sent = 20 });
    events.last_error(events.ctx, .authentication);
    events.status(events.ctx, .connected);
    return true;
}

fn daemonMockStop(
    ptr: *anyopaque,
    timeout_ms: u32,
    events: net_conn.Connection.Events,
) void {
    const self: *DaemonMockConnection = @ptrCast(@alignCast(ptr));
    self.timeout_ms = timeout_ms;
    events.status(events.ctx, .disconnecting);
    events.status(events.ctx, .disconnected);
}

fn daemonMockBetterPath(
    _: *anyopaque,
    _: net_conn.Connection.Events,
) void {}

fn daemonMockNetworkChange(
    _: *anyopaque,
    _: net_io.ReachabilityInfo,
    _: net_conn.Connection.Events,
) void {}

fn daemonMockDeinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const self: *DaemonMockConnection = @ptrCast(@alignCast(ptr));
    allocator.destroy(self);
}

pub fn mockConnectionImplementation() net_conn.ConnectionImplementation {
    return .{ .vtable = &mock_connection_implementation_vtable };
}

const mock_connection_implementation_vtable = net_conn.ConnectionImplementation.VTable{
    .module_type = openVPNModuleType,
    .create_connection = mockCreate,
};

fn openVPNModuleType(_: ?*anyopaque) api.ModuleType {
    return .OpenVPN;
}

fn mockCreate(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    module: net_conn.ConnectionModule,
    parameters: net_sandbox.Sandbox,
) net_conn.CreateError!net_conn.Connection {
    std.debug.assert(module.typeOf() == .OpenVPN);
    std.debug.assert(api.hasConnection(parameters.profile.*));
    std.debug.assert(parameters.controller.ptr != null);
    std.debug.assert(parameters.monitor.ptr != null);
    var created = try allocator.create(DaemonMockConnection);
    created.* = .{};
    return created.asConnection();
}

pub const BlockingStopConnection = struct {
    stop_count: usize = 0,
    better_path_count: usize = 0,

    fn asConnection(self: *BlockingStopConnection) net_conn.Connection {
        return .{
            .ptr = self,
            .vtable = &blocking_connection_vtable,
        };
    }
};

const blocking_connection_vtable = net_conn.Connection.VTable{
    .start = blockingStart,
    .stop = blockingStop,
    .network_change = blockingNetworkChange,
    .better_path = blockingBetterPath,
    .deinit = blockingDeinit,
};

fn blockingStart(_: *anyopaque, events: net_conn.Connection.Events) net_conn.StartError!bool {
    events.status(events.ctx, .connecting);
    events.status(events.ctx, .connected);
    return true;
}

fn blockingStop(
    ptr: *anyopaque,
    _: u32,
    events: net_conn.Connection.Events,
) void {
    const self: *BlockingStopConnection = @ptrCast(@alignCast(ptr));
    self.stop_count += 1;
    events.status(events.ctx, .disconnecting);
    events.status(events.ctx, .disconnected);
}

fn blockingBetterPath(ptr: *anyopaque, _: net_conn.Connection.Events) void {
    const self: *BlockingStopConnection = @ptrCast(@alignCast(ptr));
    self.better_path_count += 1;
}

fn blockingNetworkChange(_: *anyopaque, _: net_io.ReachabilityInfo, _: net_conn.Connection.Events) void {}

fn blockingDeinit(_: *anyopaque, _: std.mem.Allocator) void {}

pub fn blockingConnectionImplementation(blocking_connection: *BlockingStopConnection) net_conn.ConnectionImplementation {
    return .{
        .ptr = blocking_connection,
        .vtable = &blocking_connection_implementation_vtable,
    };
}

const blocking_connection_implementation_vtable = net_conn.ConnectionImplementation.VTable{
    .module_type = openVPNModuleType,
    .create_connection = blockingCreate,
};

fn blockingCreate(
    ptr: ?*anyopaque,
    _: std.mem.Allocator,
    module: net_conn.ConnectionModule,
    parameters: net_sandbox.Sandbox,
) net_conn.CreateError!net_conn.Connection {
    std.debug.assert(module.typeOf() == .OpenVPN);
    std.debug.assert(api.hasConnection(parameters.profile.*));
    const self: *BlockingStopConnection = @ptrCast(@alignCast(ptr.?));
    return self.asConnection();
}

pub fn dnsOnlyProfileJson() [:0]const u8 {
    return
    \\{
    \\  "version": 2,
    \\  "id": "00000000-0000-4000-8000-000000000000",
    \\  "name": "DNS only",
    \\  "modules": [
    \\    {
    \\      "type": "DNS",
    \\      "value": {
    \\        "id": "11111111-1111-4111-8111-111111111111",
    \\        "protocolType": { "type": "cleartext" },
    \\        "servers": ["1.1.1.1", "9.9.9.9"]
    \\      }
    \\    }
    \\  ],
    \\  "activeModulesIds": ["11111111-1111-4111-8111-111111111111"]
    \\}
    ;
}

pub fn connectionProfileJson() [:0]const u8 {
    return
    \\{
    \\  "version": 2,
    \\  "id": "00000000-0000-4000-8000-000000000000",
    \\  "name": "Connection",
    \\  "modules": [
    \\    {
    \\      "type": "OpenVPN",
    \\      "value": {
    \\        "id": "44444444-4444-4444-8444-444444444444",
    \\        "configuration": {}
    \\      }
    \\    }
    \\  ],
    \\  "activeModulesIds": ["44444444-4444-4444-8444-444444444444"]
    \\}
    ;
}
