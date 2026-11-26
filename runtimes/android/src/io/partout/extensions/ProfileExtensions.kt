// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout.extensions

import io.partout.models.TaggedModule
import io.partout.models.TaggedProfile
import io.partout.models.TunnelRemoteInfoWrapper

/**
 * Resolves the modules in the order in which they must be applied to tunnel
 * settings.
 *
 * A profile contains the modules declared by the user. The wrapper's optional
 * `modules` field contains settings derived from a connection, such as the IP
 * and DNS modules negotiated by OpenVPN. These derived modules belong directly
 * after the connection module that produced them.
 *
 * Settings-only profiles have no derived modules, so their active profile
 * modules are returned unchanged.
 */
val TunnelRemoteInfoWrapper.modulesForTunnelSettings: List<TaggedModule>
    get() {
        val activeProfileModules = profile.modules.filter { profileModule ->
            profileModule.moduleId in profile.activeModulesIds
        }
        val computedModules = activeProfileModules.toMutableList()
        if (modules != null) {
            val connectionDerivedModules = modules
            val connectionModuleIndex = computedModules.indexOfFirst { profileModule ->
                profileModule.moduleId == originalModuleId
            }
            if (connectionModuleIndex >= 0) {
                computedModules.addAll(connectionModuleIndex + 1, connectionDerivedModules)
            }
        }
        return computedModules
    }

val TaggedProfile.isInteractive: Boolean
    get() = modules.any {
        activeModulesIds.contains(it.moduleId) && it.isInteractive
    }

val TaggedProfile.interactiveModule: TaggedModule?
    get() = modules.firstOrNull {
        it.moduleId in activeModulesIds && it.isInteractive
    }

fun TaggedProfile.withInteractiveLogin(
    username: String,
    password: String,
    otp: String? = null
): TaggedProfile {
    val candidate = interactiveModule ?: return this
    return copy(
        modules = modules.map { tagged ->
            if (tagged.moduleId == candidate.moduleId) {
                tagged.withInteractiveLogin(username, password, otp)
            } else {
                tagged
            }
        }
    )
}
