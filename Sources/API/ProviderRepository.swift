// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore
import PartoutProviders

public protocol ProviderRepository: AnyObject {
    var providerId: ProviderID { get }

    func availableOptions(for moduleType: ModuleType) async throws -> ProviderFilterOptions

    func filteredServers(with parameters: ProviderServerParameters?) async throws -> [ProviderServer]
}
