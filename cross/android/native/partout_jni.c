/*
 * SPDX-FileCopyrightText: 2026 Davide De Rosa
 *
 * SPDX-License-Identifier: GPL-3.0
 */

#include "runtime.h"

#if defined(__ANDROID__)
#include <stdlib.h>
#include <android/log.h>
#include "partout.h"

#define PARTOUT_JNI_CB(e, c) PARTOUT_CB(abi_completion_proxy, abi_handler_create(e, c))
static void daemon_bindings_free(partout_daemon_bindings *b);

static void android_logger(void *ctx, const char *profile_id, int level, const char *message) {
    const char *tag = ctx ? (const char *)ctx : "Partout";
    int android_level = 0;
    switch (level) {
        case PartoutLogLevelDebug:
            android_level = ANDROID_LOG_VERBOSE;
            break;
        case PartoutLogLevelInfo:
            android_level = ANDROID_LOG_DEBUG;
            break;
        case PartoutLogLevelNotice:
            android_level = ANDROID_LOG_INFO;
            break;
        case PartoutLogLevelError:
            android_level = ANDROID_LOG_WARN;
            break;
        case PartoutLogLevelFault:
            android_level = ANDROID_LOG_FATAL;
            break;
    }
    if (profile_id) {
        __android_log_print(android_level, tag, "[%s] %s", profile_id, message);
    } else {
        __android_log_print(android_level, tag, "%s", message);
    }
}

JNIEXPORT void JNICALL
Java_io_partout_PartoutWrapper_partoutInit(
        JNIEnv *env,
        jobject thiz,
        jstring tag,
        jboolean logs_private_data
) {
    (void)thiz;
    partout_init_args args = { 0 };
    const char *jni_tag = (*env)->GetStringUTFChars(env, tag, NULL);
    char *c_tag = jni_tag ? pp_dup(jni_tag) : NULL;
    args.log_level = PartoutLogLevelDebug;
    args.logs_private_data = logs_private_data;
    args.logger_fn = android_logger;
    args.logger_ctx = (void *)c_tag;
    partout_init(&args);
    if (jni_tag) (*env)->ReleaseStringUTFChars(env, tag, jni_tag);
    // XXX: The tag must outlive the call, so we agree on leaking
    // this tiny allocation once. It's acceptable compared to
    // ensuring a more complex lifetime, because there's no clear
    // partout_deinit() counterpart to deallocate the tag.
    // pp_free(c_tag);
}

JNIEXPORT jstring JNICALL
Java_io_partout_PartoutWrapper_partoutVersion(JNIEnv *env, jobject thiz) {
    (void)thiz;
    jstring jmsg = (*env)->NewStringUTF(env, partout_version());
    return jmsg;
}

JNIEXPORT jstring JNICALL
Java_io_partout_PartoutWrapper_partoutImportProfile(
        JNIEnv *env,
        jobject thiz,
        jstring text,
        jstring name
) {
    (void)thiz;
    const char *jni_text = (*env)->GetStringUTFChars(env, text, NULL);
    const char *jni_name = name ? (*env)->GetStringUTFChars(env, name, NULL) : NULL;
    char *json = partout_import_profile(jni_text, jni_name);
    (*env)->ReleaseStringUTFChars(env, text, jni_text);
    if (jni_name) (*env)->ReleaseStringUTFChars(env, name, jni_name);

    jstring j_json = json ? (*env)->NewStringUTF(env, json) : NULL;
    free(json);
    return j_json;
}

JNIEXPORT jstring JNICALL
Java_io_partout_PartoutWrapper_partoutImportModule(
        JNIEnv *env,
        jobject thiz,
        jstring text,
        jstring context
) {
    (void)thiz;
    const char *jni_text = (*env)->GetStringUTFChars(env, text, NULL);
    if (!jni_text) return NULL;
    const char *jni_context = context ? (*env)->GetStringUTFChars(env, context, NULL) : NULL;
    if (context && !jni_context) {
        (*env)->ReleaseStringUTFChars(env, text, jni_text);
        return NULL;
    }
    char *json = partout_import_module(jni_text, jni_context);
    (*env)->ReleaseStringUTFChars(env, text, jni_text);
    if (jni_context) (*env)->ReleaseStringUTFChars(env, context, jni_context);

    jstring j_json = json ? (*env)->NewStringUTF(env, json) : NULL;
    free(json);
    return j_json;
}

JNIEXPORT jstring JNICALL
Java_io_partout_PartoutWrapper_partoutExportModule(JNIEnv *env, jobject thiz, jstring module) {
    (void)thiz;
    const char *input = (*env)->GetStringUTFChars(env, module, NULL);
    if (!input) return NULL;
    char *output = partout_export_module(input);
    (*env)->ReleaseStringUTFChars(env, module, input);
    jstring result = output ? (*env)->NewStringUTF(env, output) : NULL;
    free(output);
    return result;
}

JNIEXPORT jint JNICALL
Java_io_partout_PartoutWrapper_partoutDaemonStart(
        JNIEnv *env,
        jobject thiz,
        jstring profile,
        jstring cacheDir,
        jobject controller,
        jlong minDataCountDelta,
        jint cryptoBackend,
        jlong featureFlags
) {
    (void) thiz;
    const char *jni_profile = (*env)->GetStringUTFChars(env, profile, NULL);
    const char *jni_cache_dir = (*env)->GetStringUTFChars(env, cacheDir, NULL);

    partout_daemon_bindings bindings = {0};
    bindings.controller = (*env)->NewGlobalRef(env, controller);
    if (!bindings.controller) {
        if (jni_profile) (*env)->ReleaseStringUTFChars(env, profile, jni_profile);
        if (jni_cache_dir) (*env)->ReleaseStringUTFChars(env, cacheDir, jni_cache_dir);
        return PartoutCompletionCodeMemory;
    }
    bindings.controller_functions = partout_android_controller_functions();
    bindings.release = daemon_bindings_free;

    partout_daemon_start_args args = {0};
    args.profile = jni_profile;
    args.options.is_daemon = false;
    args.options.cancels_unrecoverable = true;
    args.options.cache_dir = jni_cache_dir;
    args.options.min_data_count_delta = minDataCountDelta;
    args.options.crypto = cryptoBackend;
    args.options.feature_flags = (uint64_t) featureFlags;
    args.bindings = &bindings;
    const jint result = partout_daemon_start(&args);

    (*env)->ReleaseStringUTFChars(env, profile, jni_profile);
    (*env)->ReleaseStringUTFChars(env, cacheDir, jni_cache_dir);
    return result;
}

JNIEXPORT void JNICALL
Java_io_partout_PartoutWrapper_partoutDaemonHold(JNIEnv *env, jobject thiz) {
    (void)env;
    (void)thiz;
    partout_daemon_hold();
}

JNIEXPORT void JNICALL
Java_io_partout_PartoutWrapper_partoutDaemonStop(
        JNIEnv *env,
        jobject thiz
) {
    (void)env;
    (void)thiz;
    partout_daemon_stop();
}

JNIEXPORT jstring JNICALL
Java_io_partout_PartoutWrapper_partoutWireGuardGenKey(JNIEnv *env, jobject thiz) {
    (void)thiz;
    char *output = partout_wireguard_genkey();
    jstring result = output ? (*env)->NewStringUTF(env, output) : NULL;
    free(output);
    return result;
}

JNIEXPORT jstring JNICALL
Java_io_partout_PartoutWrapper_partoutWireGuardPubKey(JNIEnv *env, jobject thiz, jstring key) {
    (void)thiz;
    const char *input = (*env)->GetStringUTFChars(env, key, NULL);
    if (!input) return NULL;
    char *output = partout_wireguard_pubkey(input);
    (*env)->ReleaseStringUTFChars(env, key, input);
    jstring result = output ? (*env)->NewStringUTF(env, output) : NULL;
    free(output);
    return result;
}


void daemon_bindings_free(partout_daemon_bindings *b) {
    PP_JNI_ATTACH_OR_RETURN_VOID(env);
    if (b->controller) {
        (*env)->DeleteGlobalRef(env, b->controller);
        b->controller = NULL;
    }
    PP_JNI_DETACH(env);
}
#else
typedef int partout_jni_disabled;
#endif
