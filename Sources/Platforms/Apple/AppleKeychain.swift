//
//  AppleKeychain.swift
//  Partout
//
//  Created by Davide De Rosa on 2/12/17.
//  Copyright (c) 2025 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Partout.
//
//  Partout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Partout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Partout.  If not, see <http://www.gnu.org/licenses/>.
//
//  This file incorporates work covered by the following copyright and
//  permission notice:
//
//      Copyright (c) 2018-Present Private Internet Access
//
//      Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//      The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
//      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import Foundation
import PartoutCore

/// The Apple ``Keychain``.
public final class AppleKeychain: Keychain {
    private let ctx: PartoutContext

    private let accessGroup: String?

    /**
     Creates a keychain.

     - Parameter group: An optional App Group.
     - Precondition: Proper App Group entitlements (if group is non-nil).
     **/
    public init(_ ctx: PartoutContext, group: String?) {
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
