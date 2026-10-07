// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

const helpers = @import("looper_helpers.zig");

/// One-shot worker-to-looper notification. Arm/cancel on the looper queue,
/// signal from any thread. Storage must survive until the producer has joined.
/// All fields except the immutable task are protected by the looper mutex.
pub const Notification = struct {
    task: helpers.TimedTask,
    armed: bool = false,
    ready: bool = false,
    next: ?*Notification = null,
};
