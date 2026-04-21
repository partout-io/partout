// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import PartoutCore
@testable import PartoutOpenVPNConnection
import Testing

struct ConfigurationTests {
    @Test
    func givenRandomizeHostnames_whenProcessRemotes_thenHostnamesHaveAlphanumericPrefix() throws {
        var builder = OpenVPN.Configuration.Builder()
        let hostname = "my.host.name"
        let ipv4 = "1.2.3.4"
        builder.remotes = [
            try? ExtendedEndpoint(hostname, .init(.udp, 1111)),
            try? ExtendedEndpoint(ipv4, .init(.udp4, 3333))
        ].compactMap { $0 }
        builder.randomizeHostnames = true
        let cfg = try builder.build(isClient: false)

        try cfg.processedRemotes(prng: MockPRNG())?
            .forEach {
                let comps = $0.address.rawValue.components(separatedBy: ".")
                let first = try #require(comps.first)
                if $0.isHostname {
                    #expect($0.address.rawValue.hasSuffix(hostname))
                    #expect(first.count == 12)
                    #expect(first.allSatisfy("0123456789abcdef".contains))
                } else {
                    #expect($0.address.rawValue == ipv4)
                }
            }
    }

    @Test
    func givenDataCiphersAndFallback_whenBuildingNegotiableDataCiphers_thenAppendsFallbackCipher() throws {
        var builder = OpenVPN.Configuration.Builder()
        builder.cipher = .aes128cbc
        builder.dataCiphers = [.aes256gcm, .aes128gcm]
        let cfg = try builder.build(isClient: false)

        #expect(cfg.negotiableDataCiphers == [.aes256gcm, .aes128gcm, .aes128cbc])
    }

    @Test
    func givenServerCipher_whenNegotiatingDataChannel_thenUsesServerCipher() throws {
        var localBuilder = OpenVPN.Configuration.Builder()
        localBuilder.cipher = .aes128cbc
        localBuilder.dataCiphers = [.aes256gcm, .aes128gcm]
        let local = try localBuilder.build(isClient: false)

        var pushedBuilder = OpenVPN.Configuration.Builder()
        pushedBuilder.cipher = .aes128gcm
        let pushed = try pushedBuilder.build(isClient: false)

        #expect(local.negotiatedDataChannelCipher(with: pushed, serverOptions: nil) == .aes128gcm)
    }

    @Test
    func givenServerOptionsCipherInNegotiableList_whenNegotiatingDataChannel_thenUsesServerCipher() throws {
        var localBuilder = OpenVPN.Configuration.Builder()
        localBuilder.cipher = .aes128cbc
        localBuilder.dataCiphers = [.aes256gcm, .aes128gcm]
        let local = try localBuilder.build(isClient: false)

        let pushed = try OpenVPN.Configuration.Builder().build(isClient: false)

        let server = OpenVPN.ServerOCC(
            cipher: .aes128gcm,
            digest: nil
        )

        #expect(local.negotiatedDataChannelCipher(with: pushed, serverOptions: server) == .aes128gcm)
    }

    @Test
    func givenOnlyDataCiphers_whenBuildingLocalOCCOptions_thenOmitsLegacyCipher() throws {
        var builder = OpenVPN.Configuration.Builder()
        builder.dataCiphers = [.aes256cbc]
        let options = try builder.build(isClient: false)

        let occ = options.asLocalOptionsString(withLocalOptions: true)

        #expect(!occ.contains("cipher "))
        #expect(!occ.contains("keysize "))
        #expect(occ.contains("auth SHA1"))
    }

    @Test
    func givenExplicitCipher_whenBuildingLocalOCCOptions_thenIncludesLegacyCipher() throws {
        var builder = OpenVPN.Configuration.Builder()
        builder.cipher = .aes128cbc
        builder.dataCiphers = [.aes256gcm, .aes128gcm]
        let options = try builder.build(isClient: false)

        let occ = options.asLocalOptionsString(withLocalOptions: true)

        #expect(occ.contains("cipher AES-128-CBC"))
        #expect(occ.contains("keysize 128"))
    }

    @Test
    func givenOCCServerOptionsString_whenParsing_thenIgnoresNonProfileTokensAndExtractsCipher() throws {
        let serverOptions = OpenVPN.ServerOCC.parsed(
            from: "V4,dev-type tun,link-mtu 1569,tun-mtu 1500,proto UDPv4,keydir 0,cipher AES-256-CBC,auth SHA256,keysize 256,tls-auth,key-method 2,tls-server"
        )

        #expect(serverOptions.cipher == .aes256cbc)
        #expect(serverOptions.digest == .sha256)
    }

    @Test
    func givenOCCFallbackCipherAlias_whenParsing_thenMapsItToCipher() throws {
        let serverOptions = OpenVPN.ServerOCC.parsed(
            from: "V4,data-ciphers-fallback AES-128-CBC,auth SHA1"
        )

        #expect(serverOptions.cipher == .aes128cbc)
        #expect(serverOptions.digest == .sha1)
    }

    @Test
    func givenNoServerCipher_whenNegotiatingDataChannel_thenUsesFallbackCipher() throws {
        var localBuilder = OpenVPN.Configuration.Builder()
        localBuilder.cipher = .aes256cbc
        let local = try localBuilder.build(isClient: false)

        let pushed = try OpenVPN.Configuration.Builder().build(isClient: false)

        #expect(local.negotiatedDataChannelCipher(with: pushed, serverOptions: nil) == .aes256cbc)
    }
}

private final class MockPRNG: PRNGProtocol {
    func uint32() -> UInt32 {
        1
    }

    func data(length: Int) -> Data {
        Data(Array(repeating: 1, count: length))
    }

    func safeData(length: Int) -> SecureData {
        SecureData(data(length: length))
    }
}
