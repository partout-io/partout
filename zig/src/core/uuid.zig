// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");

const c_mod = @import("../c/exports.zig");
const c = c_mod.common;

/// Errors reported while generating UUIDs.
const Error = error{
    RandomFailure,
};

/// Canonical ASCII UUID string: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
pub const UUID = [36]u8;
/// All-zero UUID sentinel used where a schema id is not available.
pub const zero_id: UUID = literal("00000000-0000-0000-0000-000000000000");

const hex_upper = "0123456789ABCDEF";

/// Generates a random RFC 4122 version 4 UUID.
pub fn newId() error{IdGeneration}!UUID {
    return v4() catch error.IdGeneration;
}

/// Generates a random RFC 4122 version 4 UUID.
fn v4() Error!UUID {
    var bytes: [16]u8 = undefined;
    if (!c.pp_prng_do(bytes[0..].ptr, bytes.len)) return error.RandomFailure;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return encode(bytes);
}

/// Parses a canonical UUID string.
///
/// Returns null when `raw` is not 36 bytes with hyphens in the canonical
/// positions and hexadecimal digits elsewhere.
pub fn parse(raw: []const u8) ?UUID {
    if (!isValid(raw)) return null;
    var out: UUID = undefined;
    @memcpy(out[0..], raw);
    return out;
}

/// Checks canonical UUID spelling without enforcing a specific version.
pub fn isValid(raw: []const u8) bool {
    if (raw.len != 36) return false;
    if (raw[8] != '-' or raw[13] != '-' or raw[18] != '-' or raw[23] != '-') return false;
    for (raw, 0..) |char, index| {
        switch (index) {
            8, 13, 18, 23 => {},
            else => if (!isHex(char)) return false,
        }
    }
    return true;
}

/// Checks whether `raw` is a canonical RFC 4122 version 4 UUID string.
pub fn isV4(raw: []const u8) bool {
    if (!isValid(raw)) return false;
    if (raw[14] != '4') return false;
    return switch (raw[19]) {
        '8', '9', 'A', 'B', 'a', 'b' => true,
        else => false,
    };
}

fn encode(bytes: [16]u8) UUID {
    var out: UUID = undefined;
    var index: usize = 0;
    for (bytes, 0..) |byte, byte_index| {
        switch (byte_index) {
            4, 6, 8, 10 => {
                out[index] = '-';
                index += 1;
            },
            else => {},
        }
        out[index] = hex_upper[byte >> 4];
        out[index + 1] = hex_upper[byte & 0x0f];
        index += 2;
    }
    return out;
}

fn literal(comptime raw: []const u8) UUID {
    if (raw.len != 36) @compileError("UUID literals must be 36 bytes");
    var out: UUID = undefined;
    @memcpy(out[0..], raw);
    return out;
}

fn isHex(char: u8) bool {
    return (char >= '0' and char <= '9') or
        (char >= 'A' and char <= 'F') or
        (char >= 'a' and char <= 'f');
}
