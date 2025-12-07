// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@testable import PartoutCore
import Testing

struct LoggableModuleTests {
    @Test
    func givenModule_whenLog_thenReturnsHandlerID() {
        let sut = SomeModule()
        let loggable = LoggableModule(.global, sut)
        #expect(
            loggable.debugDescription(withSensitiveData: true)
            ==
            sut.moduleHandler.id.debugDescription
        )
    }

#if !MINI_FOUNDATION_COMPAT
    @Test
    func givenEncodableModule_whenLog_thenDoesNotReturnHandlerID() {
        let sut = SomeEncodableModule()
        let loggable = LoggableModule(.global, sut)
        #expect(
            loggable.debugDescription(withSensitiveData: true)
            !=
            sut.moduleHandler.id.debugDescription
        )
    }
#endif

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

private struct SomeModule: Module {
    static var moduleHandler: ModuleHandler {
        ModuleHandler(ModuleType("SomeHandler"), factory: nil)
    }
}

private struct SomeEncodableModule: Module, Encodable {
}

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
