// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Platform-selected socket and TUN I/O with shared descriptors and options.

const common = @import("io_common.zig");
const backend = if (@import("builtin").os.tag == .windows)
    @import("io_windows.zig")
else
    @import("io_posix.zig");

pub const io_c = common.io_c;
pub const testing = common.testing;

pub const Error = common.Error;
pub const ReachabilityInfo = common.ReachabilityInfo;
pub const Side = common.Side;
pub const SocketOptions = common.SocketOptions;

pub const FileDescriptor = backend.FileDescriptor;
pub const LinkDescriptor = backend.LinkDescriptor;
pub const SocketDescriptor = backend.SocketDescriptor;
pub const SocketWrapper = backend.SocketWrapper;
pub const TunDescriptor = backend.TunDescriptor;
pub const TunWrapper = backend.TunWrapper;

/// The looper manages exactly one link and one tun (at most).
pub const DescriptorPair = union(Side) {
    link: LinkDescriptor,
    tun: TunDescriptor,
};
