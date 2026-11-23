// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0

#include "runtime.h"

JavaVM *jvm;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    jvm = vm;
    return JNI_VERSION_1_6;
}

JNIEnv *pp_jni_attach_thread(bool *did_attach) {
    JNIEnv *env;
    jint status = (*jvm)->GetEnv(jvm, (void **)&env, JNI_VERSION_1_6);
    switch (status) {
        case JNI_OK:
            *did_attach = false;
            return env;
        case JNI_EDETACHED:
            status = (*jvm)->AttachCurrentThread(jvm, &env, NULL);
            if (status != JNI_OK) {
                pp_clog_v(PPLogLevelFault, "AttachCurrentThread failed (%d)", status);
                return NULL;
            }
            *did_attach = true;
            return env;
        default:
            pp_clog_v(PPLogLevelFault, "GetEnv failed (%d)", status);
            return NULL;
    }
}

