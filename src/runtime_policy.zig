// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Platform availability of the legacy stack. ABI runtime selects the stack.
const builtin = @import("builtin");

/// Force v2 and exclude legacy implementations, regardless of runtime flags.
/// Set to true when all platforms migrate, or false to restore flag selection.
pub const v2_only = builtin.os.tag == .windows;

const looper = @import("net/looper.zig");
pub const legacy_looper = if (v2_only) struct {} else looper;
