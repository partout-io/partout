// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! Adapts the public C ABI to profile import/export, JSON result envelopes,
//! and daemon lifecycle management with host-supplied controller bindings.

const helpers = @import("helpers.zig");
const runtime = @import("runtime.zig");

pub const partout_c = helpers.partout_c;
pub const Importer = helpers.Importer;
pub const ImportAndEncodeError = helpers.ImportAndEncodeError;
pub const errorPayloadAllocZ = helpers.errorPayloadAllocZ;
pub const importErrorPayloadAllocZ = helpers.importErrorPayloadAllocZ;
pub const successPayloadAllocZ = helpers.successPayloadAllocZ;

pub const DaemonOptions = runtime.DaemonOptions;
pub const DaemonRuntime = runtime.DaemonRuntime;
pub const RuntimeError = runtime.RuntimeError;
