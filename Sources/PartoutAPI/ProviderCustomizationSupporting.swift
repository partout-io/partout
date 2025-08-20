// SPDX-FileCopyrightText: 2025 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

import Foundation
#if !PARTOUT_MONOLITH
import PartoutCore
#endif

// FIXME: #507/passepartout, ridiculously complex
public protocol ProviderCustomizationSupporting {
    associatedtype ProviderCustomization: UserInfoCodable

    static var providerCustomizationType: ProviderCustomization.Type { get }
}
