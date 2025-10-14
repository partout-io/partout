// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation

// Label -> Name
// Description -> Kind
// Service -> Where
// Account -> Account

/// Defines keychain access and modification.
public protocol Keychain: Sendable {

    // MARK: Password

    /**
     Sets a password.

     - Parameter password: The password to set.
     - Parameter username: The username to set the password for.
     - Parameter label: An optional label.
     - Returns: The reference to the password.
     **/
    @discardableResult
    func set(password: String, for username: String, label: String?) throws -> Data

    /**
     Removes a password.

     - Parameter username: The username to remove the password for.
     - Returns: `true` if the password was successfully removed.
     **/
    @discardableResult
    func removePassword(for username: String) -> Bool

    /**
     Removes a password by reference.

     - Parameter reference: The reference of the password to remove.
     - Returns: `true` if the password was successfully removed.
     **/
    @discardableResult
    func removePassword(forReference reference: Data) -> Bool

    /**
     Gets a password.

     - Parameter username: The username to get the password for.
     - Returns: The password for the input username.
     **/
    func password(for username: String) throws -> String

    /**
     Gets a password reference.

     - Parameter username: The username to get the password for.
     - Returns: The password reference for the input username.
     **/
    func passwordReference(for username: String) throws -> Data

    /**
     Gets the password references of all usernames.

     - Returns: The password references for the input username.
     **/
    func allPasswordReferences() throws -> [Data]

    /**
     Gets a password associated with a password reference.

     - Parameter reference: The password reference.
     - Returns: The password for the input reference.
     **/
    func password(forReference reference: Data) throws -> String
}

/// Provides a keychain.
public protocol KeychainProviding {
    var keychain: Keychain { get }
}
