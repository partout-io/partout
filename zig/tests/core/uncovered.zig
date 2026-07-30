// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0
//
// This file intentionally is not imported by tests/all.zig. It tracks Swift
// PartoutCoreTests whose behavior is not covered by Zig src/core yet.

test "uncovered AddressTests: binary Data initializers and direct Address.network helpers" {
    return error.SkipZigTest;
}

test "uncovered AsyncStreamTests: Swift AsyncSequence/KVO helpers" {
    return error.SkipZigTest;
}

test "uncovered BidirectionalStateTests: Swift BidirectionalState utility" {
    return error.SkipZigTest;
}

test "uncovered CodingRegistryTests: legacy Swift encoding and handler registry compatibility paths" {
    return error.SkipZigTest;
}

test "uncovered CodingRegistryTests+Legacy: legacy V2 profile fixtures and unknown legacy handlers" {
    return error.SkipZigTest;
}

test "uncovered CollectionExtensionsTests: Swift collection extension helpers" {
    return error.SkipZigTest;
}

test "uncovered CZeroingDataTests and CZeroingDataExtensionsTests: Darwin CZeroingData wrapper behavior" {
    return error.SkipZigTest;
}

test "uncovered DataManipulationTests, DataNetworkTests, DataUnitTests: Foundation Data extensions" {
    return error.SkipZigTest;
}

test "uncovered DNSModuleTests: Swift module builders, legacy protocol payloads, and validation failures" {
    return error.SkipZigTest;
}

test "uncovered DNSResolverTests and SimpleDNSResolverTests: async DNS resolver runtime behavior" {
    return error.SkipZigTest;
}

test "uncovered EndpointResolverTests and EndpointResolverResolvableTests: endpoint resolver cycling and DNS lookup behavior" {
    return error.SkipZigTest;
}

test "uncovered HTTPProxyModuleTests, IPModuleTests, IPSettingsTests, OnDemandModuleTests: Swift builders and route convenience APIs" {
    return error.SkipZigTest;
}

test "uncovered LocalLoggerTests, LoggableModuleTests, SensitiveEncoderTests, SensitiveLoggingTests: Swift logging and redaction encoders" {
    return error.SkipZigTest;
}

test "uncovered MessageHandlerTests: tunnel message translation hooks" {
    return error.SkipZigTest;
}

test "uncovered ConnectionGateTests: gate binding and reachability streams" {
    return error.SkipZigTest;
}

test "uncovered PartoutCoreTests: Swift Profile.Builder construction smoke test" {
    return error.SkipZigTest;
}

test "uncovered PartoutErrorTests: Swift PartoutError wrapping and debug descriptions" {
    return error.SkipZigTest;
}

test "uncovered ProfileDiffTests: Swift profile difference calculation" {
    return error.SkipZigTest;
}

test "uncovered ProfileModulesTests and ProfileTests: Swift builders, module compatibility, copy, rebuild, and toggling semantics" {
    return error.SkipZigTest;
}

test "uncovered RingQueueTests: Swift RingQueue utility" {
    return error.SkipZigTest;
}

test "uncovered SerializationTests: redacting encoders, legacy Codable payloads, custom module restoration, and Swift TaggedProfile conversion" {
    return error.SkipZigTest;
}

test "uncovered SimpleConnectionDaemonTests and TunnelTests: connection daemon and tunnel lifecycle runtime behavior" {
    return error.SkipZigTest;
}

test "uncovered SubnetTests: IPv4 netmask string conversion constructors" {
    return error.SkipZigTest;
}

test "uncovered TimeIntervalTests: Swift TimeInterval formatting helper" {
    return error.SkipZigTest;
}
