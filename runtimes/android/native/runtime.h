// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#pragma once
#include "partout.h"
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
/* Android only. */

#include <android/multinetwork.h>
#include <jni.h>

extern JavaVM *jvm;
JNIEnv *pp_jni_attach_thread(bool *did_attach);

#define PP_JNI_ATTACH_OR_RETURN(env_name, return_value) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) return return_value

#define PP_JNI_ATTACH_OR_RETURN_VOID(env_name) \
    bool env_name##_did_attach; \
    JNIEnv *env_name = pp_jni_attach_thread(&env_name##_did_attach); \
    if (!(env_name)) return

#define PP_JNI_DETACH(env_name) \
    do { \
        if (env_name##_did_attach) (*jvm)->DetachCurrentThread(jvm); \
    } while (0)

#define pp_alloc(size) calloc(1, (size))
#define pp_free free
#define pp_dup strdup
#define pp_clog(level, message) __android_log_print(ANDROID_LOG_DEBUG, "Partout", "%s", (message))
#define pp_clog_v(level, ...) __android_log_print(ANDROID_LOG_DEBUG, "Partout", __VA_ARGS__)
partout_controller_functions partout_android_controller_functions(void);
