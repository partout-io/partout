// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const DataPathDecryptedTuple = @import("data_path_decrypted_tuple.zig").DataPathDecryptedTuple;
const DataPathDecryptedAndParsedTuple = @import("data_path_decrypted_and_parsed_tuple.zig").DataPathDecryptedAndParsedTuple;
const DataPathProtocol = @import("data_path_protocol.zig").DataPathProtocol;

/// Extended data-path surface used by the Swift parity tests.
pub const DataPathTestingProtocol = struct {
    data_path: DataPathProtocol,
    testing_vtable: *const TestingVTable,

    pub const TestingVTable = struct {
        assemble: *const fn (*anyopaque, std.mem.Allocator, u32, []const u8) anyerror![]u8,
        encrypt: *const fn (*anyopaque, std.mem.Allocator, u8, u32, []const u8) anyerror![]u8,
        assemble_and_encrypt: *const fn (*anyopaque, std.mem.Allocator, []const u8, u8, u32) anyerror![]u8,
        decrypt: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!DataPathDecryptedTuple,
        parse: *const fn (*anyopaque, std.mem.Allocator, []const u8, *u8) anyerror![]u8,
        decrypt_and_parse: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!DataPathDecryptedAndParsedTuple,
    };

    pub fn assemble(
        self: DataPathTestingProtocol,
        allocator: std.mem.Allocator,
        packet_id: u32,
        payload: []const u8,
    ) anyerror![]u8 {
        return self.testing_vtable.assemble(self.data_path.ptr, allocator, packet_id, payload);
    }

    pub fn encrypt(
        self: DataPathTestingProtocol,
        allocator: std.mem.Allocator,
        key: u8,
        packet_id: u32,
        assembled: []const u8,
    ) anyerror![]u8 {
        return self.testing_vtable.encrypt(self.data_path.ptr, allocator, key, packet_id, assembled);
    }

    pub fn assembleAndEncrypt(
        self: DataPathTestingProtocol,
        allocator: std.mem.Allocator,
        packet: []const u8,
        key: u8,
        packet_id: u32,
    ) anyerror![]u8 {
        return self.testing_vtable.assemble_and_encrypt(
            self.data_path.ptr,
            allocator,
            packet,
            key,
            packet_id,
        );
    }

    pub fn decrypt(
        self: DataPathTestingProtocol,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedTuple {
        return self.testing_vtable.decrypt(self.data_path.ptr, allocator, packet);
    }

    pub fn parse(
        self: DataPathTestingProtocol,
        allocator: std.mem.Allocator,
        decrypted: []const u8,
        header: *u8,
    ) anyerror![]u8 {
        return self.testing_vtable.parse(self.data_path.ptr, allocator, decrypted, header);
    }

    pub fn decryptAndParse(
        self: DataPathTestingProtocol,
        allocator: std.mem.Allocator,
        packet: []const u8,
    ) anyerror!DataPathDecryptedAndParsedTuple {
        return self.testing_vtable.decrypt_and_parse(self.data_path.ptr, allocator, packet);
    }

    pub fn deinit(self: *DataPathTestingProtocol) void {
        self.data_path.deinit();
        self.* = undefined;
    }
};
