// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! The net module turns profiles into tunnel runtime state. It sits between the
//! platform-specific host code and the connection modules, using a profile to
//! configure the local tunnel interface and to drive any remote connection that
//! the profile requires.
//!
//! A tunnel daemon receives a profile from the host runtime and interprets it as
//! the desired network state. For settings-only profiles, the daemon converts
//! the profile into platform tunnel settings and applies them through the tunnel
//! controller. For profiles with an active connection module, it also builds the
//! corresponding connection, follows reachability changes, reports status, and
//! keeps the tunnel settings aligned with the connection lifecycle.

const conn = @import("connection.zig");
const daemon = @import("daemon.zig");
const io = @import("io.zig");
const platform = @import("platform.zig");
const sandbox = @import("sandbox.zig");

pub const Connection = conn.Connection;
pub const ConnectionCreateError = conn.CreateError;
pub const ConnectionImplementation = conn.ConnectionImplementation;
pub const ConnectionModule = conn.ConnectionModule;
pub const ConnectionOptions = sandbox.ConnectionOptions;
pub const ConnectionRegistry = conn.ConnectionRegistry;
pub const ConnectionStartError = conn.StartError;
pub const Daemon = daemon.Daemon;
pub const DaemonError = daemon.Error;
pub const DNSRecord = sandbox.DNSRecord;
pub const DNSResolver = sandbox.DNSResolver;
pub const FileDescriptor = io.FileDescriptor;
pub const NetworkMonitor = sandbox.NetworkMonitor;
pub const Platform = platform.Platform;
pub const ReachabilityInfo = io.ReachabilityInfo;
pub const Sandbox = sandbox.Sandbox;
pub const SerializedExecutor = sandbox.SerializedExecutor;
pub const SocketDescriptor = io.SocketDescriptor;
pub const SocketFactory = sandbox.SocketFactory;
pub const TunnelController = sandbox.TunnelController;
pub const TunWrapper = io.TunWrapper;
