# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

cmake_minimum_required(VERSION 3.28)

if(NOT DEFINED JNI_PREFIX OR "${JNI_PREFIX}" STREQUAL "")
    message(FATAL_ERROR "JNI_PREFIX must be defined and non-empty")
endif()

# Every JNI symbol matching the prefix must also be exported.
execute_process(COMMAND "${NM}" --defined-only --format=posix "${LIBRARY}"
    OUTPUT_VARIABLE symbols COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${NM}" --dynamic --defined-only --format=posix "${LIBRARY}"
    OUTPUT_VARIABLE exports COMMAND_ERROR_IS_FATAL ANY)
string(REGEX MATCHALL "${JNI_PREFIX}[A-Za-z_0-9]+" jni_symbols "${symbols}")
string(REGEX MATCHALL "${JNI_PREFIX}[A-Za-z_0-9]+" jni_exports "${exports}")
if(NOT jni_symbols)
    message(FATAL_ERROR "No JNI symbols matching ${JNI_PREFIX} found in ${LIBRARY}")
endif()
foreach(symbol IN LISTS jni_symbols)
    if(NOT symbol IN_LIST jni_exports)
        message(FATAL_ERROR "JNI symbol is not exported: ${symbol}")
    endif()
endforeach()
