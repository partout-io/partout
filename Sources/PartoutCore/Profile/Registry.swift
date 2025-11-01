// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

/// Keeps track of known ``Module`` types and their associated logic.
public final class Registry: Sendable {
    public typealias PostDecodeBlock = @Sendable (Profile) -> Profile?

    public typealias ResolvedModuleBlock = @Sendable (Module, Profile?) throws -> Module?

    private let allHandlers: [ModuleType: ModuleHandler]

    private let allImplementations: [ModuleType: ModuleImplementation]

    let postDecodeBlock: PostDecodeBlock?

    private let resolvedModuleBlock: ResolvedModuleBlock?

    public init(
        allHandlers: [ModuleHandler],
        allImplementations: [ModuleImplementation] = [],
        postDecodeBlock: PostDecodeBlock? = nil,
        resolvedModuleBlock: ResolvedModuleBlock? = nil
    ) {
        self.allHandlers = allHandlers
            .reduce(into: [:]) {
                $0[$1.id] = $1
            }

        self.allImplementations = allImplementations
            .reduce(into: [:]) {
                $0[$1.moduleHandlerId] = $1
            }

        self.postDecodeBlock = postDecodeBlock
        self.resolvedModuleBlock = resolvedModuleBlock
    }
}

// MARK: Handlers

protocol ModuleDecoder {
    func decodedModule(from decoder: Decoder, ofType moduleType: ModuleType) throws -> Module
}

extension Registry: ModuleDecoder {
    public func handler(withId id: ModuleType) -> ModuleHandler? {
        allHandlers[id]
    }

    public func isRegistered(_ handler: ModuleHandler) -> Bool {
        allHandlers[handler.id] != nil
    }

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

// MARK: Creation

extension Registry {
    public func newModuleBuilder(withModuleType moduleType: ModuleType) -> (any ModuleBuilder)? {
        handler(withId: moduleType)?.factory?()
    }
}

// MARK: Implementations

extension Registry {
    public func implementation(for moduleBuilder: any ModuleBuilder) -> ModuleImplementation? {
        allImplementations[moduleBuilder.moduleHandler.id]
    }

    public func implementation(for moduleHandlerId: ModuleType) -> ModuleImplementation? {
        allImplementations[moduleHandlerId]
    }

    public func implementation(for moduleHandler: ModuleHandler) -> ModuleImplementation? {
        implementation(for: moduleHandler.id)
    }

    public func connection(for connectionModule: ConnectionModule, parameters: ConnectionParameters) throws -> Connection {
        let impl = implementation(for: connectionModule.moduleHandler.id)
        return try connectionModule.newConnection(with: impl, parameters: parameters)
    }
}

// MARK: Serialization

extension Registry {
    public func resolvedProfile(_ profile: Profile) throws -> Profile {
        var copy = profile.builder()
        copy.modules = try copy.modules.map {
            try resolvedModule($0, in: profile)
        }
        return try copy.build()
    }

    public func resolvedModule(_ module: Module, in profile: Profile?) throws -> Module {
        try resolvedModuleBlock?(module, profile) ?? module
    }
}

// MARK: Importing

extension Registry: ModuleImporter {
    public nonisolated func module(fromContents contents: String, object: Any?) throws -> Module {
        var wasHandled = false
        var errors: [Error] = []
        for impl in allImplementations.values {
            guard let importer = impl as? ModuleImporter else {
                continue
            }
            wasHandled = true
            do {
                return try importer.module(fromContents: contents, object: object)
            } catch {

                // URL content is not recognized by this importer, skip to next importer
                if (error as? PartoutError)?.code != .unknownImportedModule {
                    errors.append(error)
                }
                continue
            }
        }
        if let error = errors.first {
            throw PartoutError(error)
        }
        guard wasHandled else {
            throw PartoutError(.unknownImportedModule)
        }
        throw PartoutError(.parsing)
    }
}
