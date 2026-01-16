// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

protocol TLSProtocol {
    func start() throws

    func isConnected() -> Bool

    func putPlainText(_ text: String) throws

    func putRawPlainText(_ text: Data) throws

    func putCipherText(_ data: Data) throws

    func pullPlainText() throws -> Data

    func pullCipherText() throws -> Data

    func caMD5() throws -> String
}
