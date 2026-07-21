// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

pub const NativeTLSConstants = struct {
    pub const ca_filename = "ca.pem";
    pub const default_security_level: i32 = 0;
    pub const buffer_length: usize = 16 * 1024;
};
