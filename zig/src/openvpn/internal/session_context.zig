// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const core_mod = @import("../../core/exports.zig");
const constants_mod = @import("constants.zig");
const data_mod = @import("data.zig");
const helpers_mod = @import("helpers.zig");
const push_mod = @import("push.zig");
const session_negotiator_mod = @import("session_negotiator.zig");

const api = core_mod.api;

const BidirectionalState = helpers_mod.BidirectionalState;
const ControlConstants = constants_mod.Control;
const DataChannel = data_mod.DataChannel;
const DataLink = data_mod.DataLink;
const DataLinkPair = data_mod.DataLinkPair;
const Negotiator = session_negotiator_mod.Negotiator;
const PushReply = push_mod.PushReply;

/// State retained between session attempts.
pub const ActivePhase = enum {
    starting,
    started,
    stopping,
};

pub const IdleContext = struct {
    /// Cleared after AUTH_FAILED so the next attempt sends `V0 UNDEF`.
    with_local_options: bool = true,
};

/// Mutable state owned by an active session and touched only on its looper.
pub const ActiveContext = struct {
    allocator: std.mem.Allocator,
    data_link: DataLink,
    with_local_options: bool,
    remote_endpoint: api.ExtendedEndpoint,

    negotiators: [ControlConstants.number_of_keys]?*Negotiator,
    data_channels: [ControlConstants.number_of_keys]?*DataChannel,
    old_keys: std.ArrayList(u8) = .empty,
    current_negotiator_key: ?u8 = null,
    current_data_pair: ?DataLinkPair = null,
    push_reply: ?PushReply = null,
    last_received_ns: ?u64 = null,
    last_data_count_ns: ?u64 = null,
    data_count: BidirectionalState(u64) = .init(0),

    pub fn create(
        allocator: std.mem.Allocator,
        data_link: DataLink,
        with_local_options: bool,
        remote_endpoint: api.ExtendedEndpoint,
    ) std.mem.Allocator.Error!*ActiveContext {
        const owned_address = try allocator.dupe(u8, remote_endpoint.address);
        errdefer allocator.free(owned_address);
        const self = try allocator.create(ActiveContext);
        self.* = .{
            .allocator = allocator,
            .data_link = data_link,
            .with_local_options = with_local_options,
            .remote_endpoint = .{
                .address = owned_address,
                .proto = remote_endpoint.proto,
                .owned = true,
            },
            .negotiators = [_]?*Negotiator{null} ** ControlConstants.number_of_keys,
            .data_channels = [_]?*DataChannel{null} ** ControlConstants.number_of_keys,
        };
        return self;
    }

    pub fn destroy(self: *ActiveContext) void {
        self.reset();
        self.old_keys.deinit(self.allocator);
        self.remote_endpoint.deinit(self.allocator);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn currentNegotiator(self: *ActiveContext) ?*Negotiator {
        const key = self.current_negotiator_key orelse return null;
        return self.negotiators[key];
    }

    pub fn dataChannel(self: *ActiveContext, key: u8) ?*DataChannel {
        if (key >= self.data_channels.len) return null;
        return self.data_channels[key];
    }

    /// Transfers ownership of `negotiator` to this context.
    pub fn addNegotiator(self: *ActiveContext, negotiator: *Negotiator) void {
        std.debug.assert(negotiator.key < self.negotiators.len);
        if (self.negotiators[negotiator.key]) |old| {
            if (old != negotiator) old.destroy();
        }
        self.negotiators[negotiator.key] = negotiator;
        self.current_negotiator_key = negotiator.key;
    }

    /// Transfers ownership of `channel` and makes `key` the outbound key.
    pub fn setDataChannel(
        self: *ActiveContext,
        channel: *DataChannel,
        key: u8,
    ) std.mem.Allocator.Error!void {
        std.debug.assert(key < self.data_channels.len);
        std.debug.assert(channel.key == key);
        if (self.current_data_pair) |pair| try self.old_keys.append(self.allocator, pair.key);
        if (self.data_channels[key]) |old| {
            if (old != channel) old.destroy();
        }
        self.data_channels[key] = channel;
        self.current_data_pair = .{ .link = &self.data_link, .key = key };
    }

    /// Keeps one former key alive for in-flight packets and removes older ones.
    pub fn removeOldNegotiators(self: *ActiveContext) void {
        while (self.old_keys.items.len > 1) {
            const key = self.old_keys.orderedRemove(0);
            if (self.negotiators[key]) |negotiator| negotiator.destroy();
            if (self.data_channels[key]) |channel| channel.destroy();
            self.negotiators[key] = null;
            self.data_channels[key] = null;
        }
    }

    /// Transfers ownership of the parsed reply to this context.
    pub fn setPushReply(self: *ActiveContext, reply: PushReply) void {
        if (self.push_reply) |*old| old.deinit(self.allocator);
        self.push_reply = reply;
    }

    pub fn reset(self: *ActiveContext) void {
        for (&self.negotiators) |*slot| {
            if (slot.*) |negotiator| negotiator.destroy();
            slot.* = null;
        }
        for (&self.data_channels) |*slot| {
            if (slot.*) |channel| channel.destroy();
            slot.* = null;
        }
        self.old_keys.clearRetainingCapacity();
        if (self.push_reply) |*reply| reply.deinit(self.allocator);
        self.push_reply = null;
        self.current_negotiator_key = null;
        self.current_data_pair = null;
        self.last_received_ns = null;
        self.last_data_count_ns = null;
        self.data_count.reset();
    }
};

pub const SessionState = union(enum) {
    stopped: IdleContext,
    active: Active,

    pub const Active = struct {
        phase: ActivePhase,
        context: *ActiveContext,
    };

    pub fn activeState(self: *SessionState) ?*Active {
        return switch (self.*) {
            .stopped => null,
            .active => |*active| active,
        };
    }

    pub fn activeContext(self: *SessionState) ?*ActiveContext {
        const active = self.activeState() orelse return null;
        return active.context;
    }
};

test "ActiveContext declarations are semantically analyzed" {
    std.testing.refAllDecls(ActiveContext);
}

test "stopped session has no active context" {
    var state = SessionState{ .stopped = .{ .with_local_options = false } };
    try std.testing.expect(state.activeContext() == null);
}
