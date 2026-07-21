// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const CryptoBackend = @import("crypto_backend.zig").CryptoBackend;

/// Fine tuning for an OpenVPN session. Intervals are milliseconds in Zig so
/// they can be passed to `Looper.schedule` without floating-point conversion.
pub const ConnectionOptions = struct {
    backend: CryptoBackend = .native,
    max_packets: usize = 100,
    write_timeout_ms: u64 = 5_000,
    min_data_count_interval_ms: u64 = 3_000,
    negotiation_timeout_ms: u64 = 30_000,
    hard_reset_timeout_ms: u64 = 10_000,
    tick_interval_ms: u64 = 200,
    retransmission_interval_ms: u64 = 100,
    push_request_interval_ms: u64 = 2_000,
    ping_timeout_check_interval_ms: u64 = 10_000,
    ping_timeout_ms: u64 = 120_000,
    soft_negotiation_timeout_ms: u64 = 120_000,
};
