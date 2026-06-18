// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.OpenVPNCredentials
import io.partout.models.OpenVPNCredentialsOTPMethod
import io.partout.models.TaggedModule
import io.partout.models.TaggedModuleOpenVPN
import io.partout.models.TaggedProfile

val TaggedProfile.isInteractive: Boolean
    get() = modules.any {
        activeModulesIds.contains(it.moduleId) && it.isInteractive
    }

val TaggedProfile.interactiveModule: TaggedModule?
    get() = modules.firstOrNull {
        it.moduleId in activeModulesIds && it.isInteractive
    }

fun TaggedProfile.withInteractiveOpenVPNCredentials(
    username: String,
    password: String,
    otp: String? = null
): TaggedProfile {
    val candidate = interactiveModule
    if (candidate !is TaggedModuleOpenVPN) {
        return this
    }
    val module = candidate.value
    val existingCredentials = module.credentials
    val otpMethod = existingCredentials?.otpMethod ?: OpenVPNCredentialsOTPMethod.none
    val credentialUsername = if (otpMethod == OpenVPNCredentialsOTPMethod.none) {
        username
    } else {
        existingCredentials?.username.orEmpty()
    }
    val credentialPassword = if (otpMethod == OpenVPNCredentialsOTPMethod.none) {
        password
    } else {
        otpMethod.encodedPassword(
            password = existingCredentials?.password.orEmpty(),
            otp = otp.orEmpty()
        )
    }
    val credentials = OpenVPNCredentials(
        otpMethod = OpenVPNCredentialsOTPMethod.none,
        password = credentialPassword,
        username = credentialUsername
    )
    return copy(
        modules = modules.map { tagged ->
            if (tagged is TaggedModuleOpenVPN && tagged.value.id == module.id) {
                tagged.copy(
                    value = tagged.value.copy(
                        credentials = credentials
                    )
                )
            } else {
                tagged
            }
        }
    )
}
