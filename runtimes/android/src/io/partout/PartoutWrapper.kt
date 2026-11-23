// SPDX-FileCopyrightText: 2026 Davide De Rosa
//
// SPDX-License-Identifier: GPL-3.0

package io.partout

import io.partout.abi.PartoutResult
import io.partout.models.ModuleImportContext
import io.partout.models.ModuleImportContextOpenVPN
import io.partout.models.ABIEnvelope
import io.partout.models.PartoutErrorCode
import io.partout.models.TaggedModule
import io.partout.models.TaggedProfile
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement

interface PartoutWrapperProtocol {
    fun partoutInit(tag: String, logsPrivateData: Boolean)
    fun partoutVersion(): String
    fun partoutImportProfile(
        text: String,
        name: String?
    ): String?
    fun partoutImportModule(text: String, context: String?): String?
    fun partoutExportModule(module: String): String?
    fun partoutDaemonStart(
        profile: String,
        cacheDir: String,
        controller: NativeTunnelControllerJNI,
        minDataCountDelta: Long,
        cryptoBackend: Int,
        featureFlags: Long = 0
    ): Int
    fun partoutDaemonHold()
    fun partoutDaemonStop()
    fun partoutWireGuardGenKey(): String?
    fun partoutWireGuardPubKey(key: String): String?
}

class PartoutWrapper: PartoutWrapperProtocol {
    init {
        runCatching {
            // JNI shared library built by this module's CMake target.
            System.loadLibrary("partout-jni")
        }.onFailure {
            it.printStackTrace()
            error("Unable to load Partout JNI wrapper")
        }.getOrNull()
    }

    //region Convenience overloads
    suspend fun importProfile(text: String, name: String?, passphrase: String? = null): TaggedProfile {
        val input = if (passphrase != null) {
            val module = importModule(text, ModuleImportContextOpenVPN(passphrase))
            coder.encodeToString<TaggedModule>(module)
        } else {
            text
        }
        return coder.decodeFromJsonElement(importResult { partoutImportProfile(input, name) })
    }

    suspend fun importModule(text: String, context: ModuleImportContext? = null): TaggedModule {
        val contextJSON = context?.let { coder.encodeToString<ModuleImportContext>(it) }
        return coder.decodeFromJsonElement(importResult { partoutImportModule(text, contextJSON) })
    }

    fun exportModule(module: TaggedModule): String? {
        return partoutExportModule(coder.encodeToString<TaggedModule>(module))
    }

    private suspend fun importResult(block: () -> String?): JsonElement {
        val result = PartoutResult.await { completion ->
            val json = block()
            if (json != null) {
                val envelope = coder.decodeFromString<ABIEnvelope>(json)
                completion.onComplete(envelope.code, envelope.payload)
            } else {
                completion.onComplete(PartoutErrorCode.unhandled, null)
            }
        }
        return checkNotNull(result.json) { "Import succeeded without payload" }
    }
    //endregion

    //region ABI
    override external fun partoutInit(
        tag: String,
        logsPrivateData: Boolean
    )
    override external fun partoutVersion(): String
    override external fun partoutImportProfile(
        text: String,
        name: String?
    ): String?
    override external fun partoutImportModule(text: String, context: String?): String?
    override external fun partoutExportModule(module: String): String?
    override external fun partoutDaemonStart(
        profile: String,
        cacheDir: String,
        controller: NativeTunnelControllerJNI,
        minDataCountDelta: Long,
        cryptoBackend: Int,
        featureFlags: Long
    ): Int
    override external fun partoutDaemonHold()
    override external fun partoutDaemonStop()
    override external fun partoutWireGuardGenKey(): String?
    override external fun partoutWireGuardPubKey(key: String): String?
    //endregion

    companion object {
        private val coder = Json {
            ignoreUnknownKeys = true
        }
    }
}
