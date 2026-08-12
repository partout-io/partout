// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct LoggableModuleTests {
    @Test
    func givenModule_whenLog_thenReturnsModuleType() {
        let sut = SomeModule()
        let loggable = LoggableModule(.global, sut)
        #expect(
            loggable.debugDescription(withSensitiveData: true)
            ==
            sut.moduleType.debugDescription
        )
    }

    @Test
    func givenEncodableModule_whenLog_thenDoesNotReturnModuleType() {
        let sut = SomeEncodableModule()
        let loggable = LoggableModule(.global, sut)
        #expect(
            loggable.debugDescription(withSensitiveData: true)
            !=
            sut.moduleType.debugDescription
        )
    }

    @Test
    func givenDebuggableModule_whenLog_thenReturnsDebugDescription() {
        let sut = SomeDebuggableModule()
        let loggable = LoggableModule(.global, sut)
        #expect(
            loggable.debugDescription(withSensitiveData: true)
            ==
            sut.debugDescription(withSensitiveData: true)
        )
    }

    @Test
    func givenDebuggableEncodableModule_whenLog_thenReturnsDebugDescription() {
        let sut = SomeEncodableDebuggableModule()
        let loggable = LoggableModule(.global, sut)
        #expect(
            loggable.debugDescription(withSensitiveData: true)
            ==
            sut.debugDescription(withSensitiveData: true)
        )
    }
}

private struct SomeModule: Module {}

private struct SomeEncodableModule: Module, Encodable {}

private struct SomeDebuggableModule: Module, SensitiveDebugStringConvertible {
    func debugDescription(withSensitiveData: Bool) -> String {
        "SomeDebugDescription"
    }
}

private struct SomeEncodableDebuggableModule: Module, Encodable, SensitiveDebugStringConvertible {
    func debugDescription(withSensitiveData: Bool) -> String {
        "SomeDebugDescription"
    }
}
