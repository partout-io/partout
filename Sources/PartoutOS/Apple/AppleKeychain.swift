// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

#if !PARTOUT_MONOLITH
import PartoutCore
#endif

/// The Apple Keychain.
public final class AppleKeychain: Keychain {
    private let ctx: PartoutLoggerContext

    private let accessGroup: String?

    /**
     Creates a keychain.

     - Parameter ctx: The context.
     - Parameter group: An optional App Group.
     - Precondition: Proper App Group entitlements (if group is non-nil).
     **/
    public init(_ ctx: PartoutLoggerContext, group: String?) {
        self.ctx = ctx
        accessGroup = group
    }

    @discardableResult
    public func set(password: String, for username: String, label: String? = nil) throws -> Data {
        var existingReference: Data?
        do {
            let reference = try passwordReference(for: username)
            let currentPassword = try self.password(forReference: reference)

            // return existing reference if content has not changed
            guard password != currentPassword else {
                return reference
            }

            // keep going
            existingReference = reference
        } catch let error as PartoutError {

            // this is a well-known error from password() or passwordReference(), keep going

            // rethrow cancellation
            if error.code == .operationCancelled {
                throw error
            }

            // otherwise, no pre-existing password
        } catch {

            // IMPORTANT: rethrow any other unknown error (leave this code explicit)
            throw error
        }

        // update
        if let existingReference {
            var query: [String: Any] = [:]
            query[kSecValuePersistentRef as String] = existingReference

            var attributes: [String: Any] = [:]
            attributes[kSecValueData as String] = password.data(using: .utf8)
            if let label {
                attributes[kSecAttrLabel as String] = label
            }

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                pp_log(ctx, .core, .error, "set(password:for:label:) [update], keychain status is \(status)")
                throw PartoutError(.keychainAddItem)
            }
            return existingReference
        }
        // add
        else {
            var query: [String: Any] = [:]
            setScope(query: &query)
            query[kSecClass as String] = kSecClassGenericPassword
            query[kSecAttrLabel as String] = label
            query[kSecAttrAccount as String] = username
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            query[kSecValueData as String] = password.data(using: .utf8)
            query[kSecReturnPersistentRef as String] = true

            var ref: CFTypeRef?
            let status = SecItemAdd(query as CFDictionary, &ref)
            guard status == errSecSuccess else {
                pp_log(ctx, .core, .error, "set(password:for:label:) [add], keychain status is \(status)")
                throw PartoutError(.keychainAddItem)
            }
            guard let refData = ref as? Data else {
                pp_log(ctx, .core, .error, "set(password:for:label:), result is not Data")
                throw PartoutError(.decoding)
            }
            return refData
        }
    }

    @discardableResult
    public func removePassword(for username: String) -> Bool {
        var query: [String: Any] = [:]
        setScope(query: &query)
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrAccount as String] = username

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }

    public func password(for username: String) throws -> String {
        var query: [String: Any] = [:]
        setScope(query: &query)
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrAccount as String] = username
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break

        case errSecUserCanceled:
            throw PartoutError(.operationCancelled)

        case errSecItemNotFound:
            throw PartoutError(.keychainItemNotFound)

        default:
            pp_log(ctx, .core, .error, "password(for:), keychain status is \(status)")
            throw PartoutError(.keychainItemNotFound, status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            pp_log(ctx, .core, .error, "password(for:), result is not Data")
            throw PartoutError(.decoding)
        }
        return string
    }

    public func passwordReference(for username: String) throws -> Data {
        var query: [String: Any] = [:]
        setScope(query: &query)
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrAccount as String] = username
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnPersistentRef as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break

        case errSecUserCanceled:
            throw PartoutError(.operationCancelled)

        case errSecItemNotFound:
            throw PartoutError(.keychainItemNotFound)

        default:
            pp_log(ctx, .core, .error, "passwordReference(for:), keychain status is \(status)")
            throw PartoutError(.keychainItemNotFound, status)
        }
        guard let data = result as? Data else {
            pp_log(ctx, .core, .error, "passwordReference(for:), result is not Data")
            throw PartoutError(.decoding)
        }
        return data
    }

    public func allPasswordReferences() throws -> [Data] {
        var query: [String: Any] = [:]
        setScope(query: &query)
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnPersistentRef as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break

        case errSecUserCanceled:
            throw PartoutError(.operationCancelled)

        case errSecItemNotFound:
            throw PartoutError(.keychainItemNotFound)

        default:
            pp_log(ctx, .core, .error, "allPasswordReferences(), keychain status is \(status)")
            throw PartoutError(.keychainItemNotFound, status)
        }
        guard let refs = result as? [Data] else {
            pp_log(ctx, .core, .error, "allPasswordReferences(), result is not [Data]")
            throw PartoutError(.decoding)
        }
        return refs
    }

    public func password(forReference reference: Data) throws -> String {
        var query: [String: Any] = [:]
        query[kSecValuePersistentRef as String] = reference
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break

        case errSecUserCanceled:
            throw PartoutError(.operationCancelled)

        case errSecItemNotFound:
            throw PartoutError(.keychainItemNotFound)

        default:
            pp_log(ctx, .core, .error, "password(forReference:), keychain status is \(status)")
            throw PartoutError(.keychainItemNotFound, status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            pp_log(ctx, .core, .error, "password(forReference:), result is not Data")
            throw PartoutError(.decoding)
        }
        return string
    }

    @discardableResult
    public func removePassword(forReference reference: Data) -> Bool {
        var query: [String: Any] = [:]
        query[kSecValuePersistentRef as String] = reference

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
}

// MARK: - Helpers

private extension AppleKeychain {
    func setScope(query: inout [String: Any]) {
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] = true
            #endif
        }
    }
}
