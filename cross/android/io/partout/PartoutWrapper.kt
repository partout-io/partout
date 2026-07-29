// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout

import io.partout.abi.PartoutResult
import io.partout.models.TaggedProfile
import kotlinx.serialization.json.Json

interface PartoutWrapperProtocol {
    fun partoutInit(tag: String, logsPrivateData: Boolean)
    fun partoutVersion(): String
    fun partoutImportProfile(
        text: String,
        name: String?
    ): String?
    fun partoutDaemonStart(
        profile: String,
        cacheDir: String,
        controller: NativeTunnelControllerJNI,
        minDataCountDelta: Long
    ): Int
    fun partoutDaemonStop()
}

class PartoutWrapper(
    libraryName: String
): PartoutWrapperProtocol {
    init {
        runCatching {
            // Name of the NDK .so without "lib" prefix or ".so"
            System.loadLibrary(libraryName)
        }.onFailure {
            it.printStackTrace()
            error("Unable to load Partout JNI wrapper")
        }.getOrNull()
    }

    //region Convenience overloads
    suspend fun importProfile(text: String, name: String?): TaggedProfile {
        val result = runCatching {
            PartoutResult.await { completion ->
                val json = partoutImportProfile(text, name)
                val code = if (json != null) 0 else -1
                completion.onComplete(code, json)
            }
        }.getOrThrow()
        val profileJSON = result.json
        if (profileJSON == null) {
            error("partoutImportProfile() succeeded without payload")
        }
        return json.decodeFromString<TaggedProfile>(profileJSON)
    }
    //endregion

    //region ABI
    override external fun partoutInit(tag: String, logsPrivateData: Boolean)
    override external fun partoutVersion(): String
    override external fun partoutImportProfile(
        text: String,
        name: String?
    ): String?
    override external fun partoutDaemonStart(
        profile: String,
        cacheDir: String,
        controller: NativeTunnelControllerJNI,
        minDataCountDelta: Long
    ): Int
    override external fun partoutDaemonStop()
    //endregion

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
        }
    }
}
