// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
import PartoutCore

// FIXME: passepartout#507, ridiculously complex
public protocol ProviderCustomizationSupporting {
    associatedtype ProviderCustomization: UserInfoCodable

    static var providerCustomizationType: ProviderCustomization.Type { get }
}
