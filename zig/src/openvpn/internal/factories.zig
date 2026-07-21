// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

const std = @import("std");
const CryptoKeysPRF = @import("crypto_keys_prf.zig").CryptoKeysPRF;
const DataPathParameters = @import("data_path_parameters.zig").DataPathParameters;
const DataPathProtocol = @import("data_path_protocol.zig").DataPathProtocol;
const DataPathWrapper = @import("data_path_wrapper.zig").DataPathWrapper;
const PRNG = @import("prng.zig").PRNG;
const TLSParameters = @import("tls_parameters.zig").TLSParameters;
const TLSProtocol = @import("tls_protocol.zig").TLSProtocol;
const TLSWrapper = @import("tls_wrapper.zig").TLSWrapper;

pub const TLSFactory = *const fn (
    std.mem.Allocator,
    TLSParameters,
) anyerror!TLSProtocol;

pub const DataPathFactory = *const fn (
    std.mem.Allocator,
    DataPathParameters,
    /// Ownership transfers to the factory when it is called, including when
    /// the factory returns an error.
    CryptoKeysPRF,
    PRNG,
) anyerror!DataPathProtocol;

pub fn nativeTLSFactory(
    allocator: std.mem.Allocator,
    parameters: TLSParameters,
) anyerror!TLSProtocol {
    var wrapper = try TLSWrapper.native(allocator, parameters);
    const protocol = wrapper.tls;
    wrapper = undefined;
    return protocol;
}

pub fn nativeDataPathFactory(
    allocator: std.mem.Allocator,
    parameters: DataPathParameters,
    prf: CryptoKeysPRF,
    prng: PRNG,
) anyerror!DataPathProtocol {
    var owned_prf = prf;
    defer owned_prf.deinit(allocator);
    var wrapper = try DataPathWrapper.nativeWithPRF(allocator, parameters, &owned_prf, prng);
    return wrapper.takeProtocol();
}
