// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const core = @import("../../core/exports.zig");
const c = @import("c.zig").api;

const api = core.api;

pub const DataPathParameters = struct {
    fnt: c.pp_crypto_enc_fnt,
    cipher: ?api.OpenVPNCipher,
    digest: ?api.OpenVPNDigest,
    compression_framing: api.OpenVPNCompressionFraming,
    compression_algorithm: api.OpenVPNCompressionAlgorithm,
    peer_id: ?u32,
};
