// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.OpenVPNCredentials
import io.partout.models.OpenVPNCredentialsOTPMethod
import io.partout.models.OpenVPNModule
import java.util.Base64

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

fun OpenVPNCredentialsOTPMethod.encodedPassword(
    password: String,
    otp: String
): String {
    return when (this) {
        OpenVPNCredentialsOTPMethod.none -> password
        OpenVPNCredentialsOTPMethod.append -> password + otp
        OpenVPNCredentialsOTPMethod.encode -> {
            val base64Password = Base64.getEncoder().encodeToString(password.toByteArray(Charsets.UTF_8))
            val base64OTP = Base64.getEncoder().encodeToString(otp.toByteArray(Charsets.UTF_8))
            "SCRV1:$base64Password:$base64OTP"
        }
    }
}
