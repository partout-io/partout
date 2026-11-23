// Host-only substitute for Android logging; JNI itself is never mocked.
#pragma once
#define ANDROID_LOG_DEBUG 3
int __android_log_print(int priority, const char *tag, const char *format, ...);
