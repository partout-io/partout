// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

@available(*, deprecated, message: "Superseded. Used by LegacyProfileEncoderV2")
public protocol LegacyModuleDecoder {
    func decodedModule(from decoder: Decoder, ofType moduleType: ModuleType) throws -> Module
}


extension Registry: LegacyModuleDecoder {
    public func decodedModule(from decoder: Decoder, ofType moduleType: ModuleType) throws -> Module {
        guard let handler = allHandlers[moduleType] else {
            throw PartoutError(.unknownModuleHandler)
        }
        guard let handlerDecoder = handler.decoder else {
            throw PartoutError(.decoding, "Missing decoder")
        }
        return try handlerDecoder(decoder)
    }
}

