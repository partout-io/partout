// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// This file intentionally is not imported by tests/all.zig. It tracks Swift
// PartoutOpenVPNTests whose behavior is redundant or not exposed by Zig.

test "uncovered ConfigurationBuilderTests: Swift client builders materialize defaults while Zig stores schema values directly" {
    return error.SkipZigTest;
}

test "uncovered JSONTests: Swift asJSON supports sensitive-field redaction that is not part of the Zig model encoder" {
    return error.SkipZigTest;
}

test "uncovered ObfuscationMethodTests: legacy untagged Codable payloads are outside the generated tagged Zig schema" {
    return error.SkipZigTest;
}

test "uncovered DataPathPerformanceTests and native cipher cases: timing and AES backends are not portable unit tests" {
    return error.SkipZigTest;
}

test "uncovered ControlChannelTests: client-server tls-crypt pairing requires a real crypto backend" {
    return error.SkipZigTest;
}

test "uncovered OpenVPNConnectionTests: the legacy Swift V2 connection has no Zig implementation" {
    return error.SkipZigTest;
}

test "uncovered OpenVPNConnectionV3Tests: Swift injects mock sessions while the Zig connection owns a concrete Session" {
    return error.SkipZigTest;
}

test "uncovered NetworkSettingsBuilderTests: Swift ignores pushed MTU while Zig deliberately honors it with local fallback" {
    return error.SkipZigTest;
}

test "uncovered ModuleTests: module serialization round trips and static-challenge rejection are redundant with serializer.zig" {
    return error.SkipZigTest;
}

test "uncovered OpenVPNParserTests: Option regular-expression component enumeration is a Swift parser implementation detail" {
    return error.SkipZigTest;
}

test "uncovered TLSTests and Backend: Swift-only test fixtures contain no test cases" {
    return error.SkipZigTest;
}
