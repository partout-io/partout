// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.ModuleType
import io.partout.models.OpenVPNCredentials
import io.partout.models.OpenVPNCredentialsOTPMethod
import io.partout.models.OpenVPNModule
import io.partout.models.TaggedModule
import io.partout.models.TaggedModuleDNS
import io.partout.models.TaggedModuleHTTPProxy
import io.partout.models.TaggedModuleIP
import io.partout.models.TaggedModuleOnDemand
import io.partout.models.TaggedModuleOpenVPN
import io.partout.models.TaggedModuleWireGuard
import io.partout.models.TaggedProfile
import java.util.Base64

//region TaggedModule
val TaggedModule.moduleType: ModuleType?
    get() = when (this) {
        is TaggedModuleDNS -> ModuleType.DNS
        is TaggedModuleHTTPProxy -> ModuleType.HTTPProxy
        is TaggedModuleIP -> ModuleType.IP
        is TaggedModuleOnDemand -> ModuleType.OnDemand
        is TaggedModuleOpenVPN -> ModuleType.OpenVPN
        is TaggedModuleWireGuard -> ModuleType.WireGuard
        else -> null
    }

val TaggedModule.moduleId: String?
    get() = when (this) {
        is TaggedModuleDNS -> value.id
        is TaggedModuleHTTPProxy -> value.id
        is TaggedModuleIP -> value.id
        is TaggedModuleOnDemand -> value.id
        is TaggedModuleOpenVPN -> value.id
        is TaggedModuleWireGuard -> value.id
        else -> null
    }

val TaggedModule.isInteractive: Boolean
    get() = when (this) {
        is TaggedModuleOpenVPN -> value.isInteractive
        else -> false
    }
//endregion

//region TaggedProfile
val TaggedProfile.isInteractive: Boolean
    get() = modules.any {
        activeModulesIds.contains(it.moduleId) && it.isInteractive
    }

val TaggedProfile.interactiveModule: TaggedModule?
    get() = modules.firstOrNull {
        it.moduleId in activeModulesIds && it.isInteractive
    }
//endregion

//region OpenVPN
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
//endregion