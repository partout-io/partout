// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

//! A simplified implementation of the [OpenVPN][dep-openvpn] protocol.
//!
//! The client is known to work with OpenVPN 2.3+ servers.
//!
//! Supported features include:
//!
//! - Handshake and tunneling over UDP or TCP
//! - Ciphers:
//!   - AES-CBC (128/192/256 bit)
//!   - AES-GCM (128/192/256 bit, 2.4)
//! - HMAC digests:
//!   - SHA-1
//!   - SHA-2 (224/256/384/512 bit)
//! - NCP (Negotiable Crypto Parameters, 2.4):
//!   - Server-side
//! - TLS handshake:
//!   - Server validation (CA, EKU)
//!   - Client certificate
//! - TLS wrapping:
//!   - Authentication (`--tls-auth`)
//!   - Encryption (`--tls-crypt` and `--tls-crypt-v2`)
//! - Compression framing
//! - Key renegotiation
//! - Replay protection (hardcoded window)
//!
//! The library supports compression framing, just not compression. Match
//! server-side compression framing, otherwise the client will shut down with an
//! error. For example, if the server has `comp-lzo no`, the client must use
//! `.compLZO` compression framing.
//!
//! ## Tunnelblick XOR Patch
//!
//! Partout fully supports the non-standard [Tunnelblick XOR patch][dep-tunnelblick-xor]:
//!
//! - Multi-byte XOR masking:
//!   - Via `--scramble xormask <passphrase>`
//!   - XOR all incoming and outgoing bytes by the passphrase given
//! - XOR position masking:
//!   - Via `--scramble xorptrpos`
//!   - XOR all bytes by their position in the array
//! - Packet reverse scramble:
//!   - Via `--scramble reverse`
//!   - Keeps the first byte and reverses the rest of the array
//! - XOR scramble obfuscate:
//!   - Via `--scramble obfuscate <passphrase>`
//!   - Performs a combination of the three above (specifically
//!     `xormask <passphrase>` -> `xorptrpos` -> `reverse` -> `xorptrpos` for
//!     reading, and the opposite for writing)
//!
//! [dep-openvpn]: https://openvpn.net/index.php/open-source/overview.html
//! [dep-tunnelblick-xor]: https://tunnelblick.net/cOpenvpn_xorpatch.html

const std = @import("std");

const connection = @import("connection.zig");
const core = @import("../core/exports.zig");
const net = @import("../net/exports.zig");
const parser = @import("parser.zig");
const proto = @import("../proto/exports.zig");
const serializer = @import("serializer.zig");

const ModuleType = core.api.ModuleType;

pub const impl: proto.ModuleExports = .{
    .module = .{
        .ptr = null,
        .vtable = &module_vtable,
    },
    .connection = null,
    // ZIGME: Implement OpenVPN connection
    // .connection = if (build_options.openvpn) .{
    //     .ptr = &Default.connection_context,
    //     .vtable = &connection_vtable,
    // } else null,
};

const module_vtable: core.ModuleImplementation.VTable = .{
    .module_type = moduleType,
    .import_module = parser.importModule,
    .serialize_module = serializer.serializeModule,
};

// const connection_vtable: net.ConnectionImplementation.VTable = .{
//     .module_type = moduleType,
//     .create_connection = connection.createConnection,
// };

fn moduleType(_: ?*anyopaque) ModuleType {
    return .OpenVPN;
}
