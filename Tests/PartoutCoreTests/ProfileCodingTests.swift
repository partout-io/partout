// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct ProfileCodingTests {
    @Test
    func givenRegistry_whenEncodeProfileWithUnknownModule_thenFailsToDecode() throws {
        let sut = Registry(allHandlers: [])
        let module = try DNSModule.Builder().tryBuild()
        let profile = try Profile.Builder(modules: [module]).tryBuild()
        do {
            let encoded = try sut.encodedProfile(profile)
            _ = try sut.decodedProfile(from: encoded, fallingBack: false)
            #expect(Bool(false))
        } catch let error as PartoutError {
            #expect(error.code == .unknownModuleHandler)
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func givenRegistry_whenEncodeProfileWithRegisteredModule_thenIsDecoded() throws {
        let sut = Registry(allHandlers: [DNSModule.moduleHandler])
        let module = try DNSModule.Builder().tryBuild()
        let profile = try Profile.Builder(modules: [module]).tryBuild()
        expectNoThrow(try sut.encodedProfile(profile))
    }

    @Test
    func givenRegistry_whenEncodeModule_thenIsDecoded() throws {
        let sut = Registry(allHandlers: [DNSModule.moduleHandler])
        let module = try DNSModule.Builder().tryBuild()

        let encoded = try JSONEncoder().encode(CodableModule(wrappedModule: module))
        let encodedString = try #require(String(data: encoded, encoding: .utf8))
        print(encodedString)

        let decoder = JSONDecoder()
        decoder.userInfo = [.moduleDecoder: sut]
        let decoded = try decoder.decode(CodableModule.self, from: encoded)
        #expect(decoded.wrappedModule as? DNSModule == module)
    }

    @Test
    func givenRegistry_whenEncodeProfile_thenIsDecoded() throws {
        let sut = Registry(allHandlers: [DNSModule.moduleHandler])
        let module = try DNSModule.Builder().tryBuild()
        let profile = try Profile.Builder(modules: [module]).tryBuild()

        let encoded = try sut.encodedProfile(profile)
        let decoded = try sut.decodedProfile(from: encoded, fallingBack: false)
        #expect(decoded == profile)
    }

    @Test
    func givenRegistry_whenEncodeProfile_thenDecodesToEqual() throws {
        let sut = Registry(allHandlers: [
            DNSModule.moduleHandler,
            IPModule.moduleHandler
        ])
        let dnsModule = try DNSModule.Builder(
            protocolType: .tls,
            servers: ["1.1.1.1", "4.4.4.4"],
            dotHostname: "hay.com"
        ).tryBuild()
        let ipModule = IPModule.Builder(mtu: 1234).tryBuild()
        let profile = try Profile.Builder(
            modules: [dnsModule, ipModule],
            userInfo: ["foo": "bar", "zen": 12]
        ).tryBuild()

        let encodedJSON = try sut.json(fromProfile: profile)
        print(encodedJSON)
        let decodedProfile = try sut.profile(fromJSON: encodedJSON)
        print(decodedProfile)
        #expect(decodedProfile.modules[0] as? DNSModule == dnsModule)
        #expect(decodedProfile.modules[1] as? IPModule == ipModule)
        #expect(decodedProfile == profile)
    }
}
