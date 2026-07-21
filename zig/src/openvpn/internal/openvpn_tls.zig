// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

/// Namespace preserved from Swift's case-less `OpenVPNTLS` enum.
pub const OpenVPNTLS = struct {
    pub const PlainSerializer = @import("plain_serializer.zig").PlainSerializer;
    pub const AuthSerializer = @import("auth_serializer.zig").AuthSerializer;
    pub const CryptSerializer = @import("crypt_serializer.zig").CryptSerializer;
    pub const CryptV2Serializer = @import("crypt_v2_serializer.zig").CryptV2Serializer;
};

test "OpenVPNTLS namespace exposes all control serializers" {
    _ = OpenVPNTLS.PlainSerializer;
    _ = OpenVPNTLS.AuthSerializer;
    _ = OpenVPNTLS.CryptSerializer;
    _ = OpenVPNTLS.CryptV2Serializer;
}
