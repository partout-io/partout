// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.OpenVPNCredentials
import io.partout.models.OpenVPNCredentialsOTPMethod
import io.partout.models.OpenVPNModule

val OpenVPNModule.isInteractive: Boolean
    get() {
        if (requiresCredentials) {
            return true
        }
        return configuration?.staticChallenge == true ||
            requiresInteractiveCredentials == true
    }

val OpenVPNModule.requiresCredentials: Boolean
    get() = configuration?.authUserPass == true &&
        (credentials?.isEmpty ?: true)

val OpenVPNCredentials.isEmpty: Boolean
    get() = username.isEmpty() && password.isEmpty()

internal fun OpenVPNModule.withInteractiveLogin(
    username: String,
    password: String,
    otp: String?
): OpenVPNModule {
    if (!isInteractive) return this
    val existingCredentials = credentials
    val otpMethod = existingCredentials?.otpMethod ?: OpenVPNCredentialsOTPMethod.none
    return copy(
        credentials = OpenVPNCredentials(
            username = username,
            password = if (otpMethod == OpenVPNCredentialsOTPMethod.none) password else existingCredentials?.password.orEmpty(),
            otpMethod = otpMethod,
            otp = if (otpMethod == OpenVPNCredentialsOTPMethod.none) null else otp
        )
    )
}
