// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const core = @import("../../core/exports.zig");
const net = @import("../../net/looper.zig");
const SessionDelegate = @import("session_delegate.zig").SessionDelegate;

const api = core.api;

/// Type-erased synchronous session interface.
///
/// Swift's V3 boundary is `async`, but its operations serialize onto
/// `FdLooper`. The Zig looper already provides synchronous attach/detach and
/// perform operations, so suspension is unnecessary here.
pub const SessionProtocol = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        set_delegate: *const fn (*anyopaque, ?SessionDelegate) void,
        set_link: *const fn (
            *anyopaque,
            net.Looper.Descriptor,
            api.ExtendedEndpoint,
        ) anyerror!void,
        has_link: *const fn (*anyopaque) bool,
        set_tunnel: *const fn (*anyopaque, net.Looper.Descriptor) anyerror!void,
        shutdown: *const fn (*anyopaque, ?anyerror, ?u64) anyerror!void,
    };

    pub fn setDelegate(self: SessionProtocol, delegate: ?SessionDelegate) void {
        self.vtable.set_delegate(self.ptr, delegate);
    }

    pub fn setLink(
        self: SessionProtocol,
        descriptor: net.Looper.Descriptor,
        remote_endpoint: api.ExtendedEndpoint,
    ) anyerror!void {
        return self.vtable.set_link(self.ptr, descriptor, remote_endpoint);
    }

    pub fn hasLink(self: SessionProtocol) bool {
        return self.vtable.has_link(self.ptr);
    }

    pub fn setTunnel(
        self: SessionProtocol,
        descriptor: net.Looper.Descriptor,
    ) anyerror!void {
        return self.vtable.set_tunnel(self.ptr, descriptor);
    }

    pub fn shutdown(
        self: SessionProtocol,
        cause: ?anyerror,
        timeout_ms: ?u64,
    ) anyerror!void {
        return self.vtable.shutdown(self.ptr, cause, timeout_ms);
    }
};
