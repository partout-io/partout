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
pub const FileDescriptor = common.FileDescriptor;
pub const ReachabilityInfo = common.ReachabilityInfo;
pub const SocketDescriptor = common.SocketDescriptor;
pub const Side = common.Side;
pub const Error = common.Error;
pub const IOInterface = common.IOInterface;
pub const SocketOptions = common.SocketOptions;
pub const SocketWrapper = backend.SocketWrapper;
pub const TunWrapper = backend.TunWrapper;
pub const testing = common.testing;
