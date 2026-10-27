// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Platform-selected socket and TUN I/O with shared descriptors and options.

const common = @import("io_common.zig");
const builtin = @import("builtin");
const windows = @import("io_windows.zig");
const posix = @import("io_posix.zig");
const ffi = @import("../c/exports.zig");
const backend = if (builtin.os.tag == .windows) windows else posix;

pub const testing = common.testing;

pub const Packet = common.Packet;
pub const Packets = common.Packets;
pub const ReadAction = common.ReadAction;

pub const Failure = common.Failure;
pub const TimedTask = common.TimedTask;
pub const Timer = common.Timer;

pub const Error = common.Error;
pub const ReachabilityInfo = common.ReachabilityInfo;
pub const Side = common.Side;
pub const SocketOptions = common.SocketOptions;
pub const Waiter = common.Waiter;

// Native ABI types, independent of the platform's link representation.
pub const FileDescriptor = ffi.io.pp_fd;
pub const LinkDescriptor = backend.LinkDescriptor;
pub const SocketDescriptor = ffi.io.pp_socket_fd;
pub const SocketWrapper = backend.SocketWrapper;
pub const TunDescriptor = backend.TunDescriptor;
pub const TunWrapper = backend.TunWrapper;

pub const SocketAddress = common.SocketAddress;
pub const SocketEndpoint = common.SocketEndpoint;
pub const SocketType = common.SocketType;
pub const Datagram = common.Datagram;

pub const DescriptorPair = union(Side) {
    link: LinkDescriptor,
    tun: TunDescriptor,
};

/// Owns callback delivery and packet submission using the selected backend.
pub const CallbackTransport = backend.CallbackTransport(DescriptorPair);
