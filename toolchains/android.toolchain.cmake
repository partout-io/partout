# SPDX-FileCopyrightText: 2026 Davide De Rosa
#
# SPDX-License-Identifier: MIT

# From environment
# ANDROID_NDK_HOME
# SWIFT_ANDROID_ABI
# SWIFT_ANDROID_ARCH
# SWIFT_ANDROID_API_LEVEL
# SWIFT_ANDROID_VERSION

if(NOT DEFINED ENV{ANDROID_NDK_HOME} OR "$ENV{ANDROID_NDK_HOME}" STREQUAL "")
    message(FATAL_ERROR "ANDROID_NDK_HOME must be defined")
endif()
if(NOT IS_DIRECTORY "$ENV{ANDROID_NDK_HOME}")
    message(FATAL_ERROR "ANDROID_NDK_HOME must point to an existing directory: $ENV{ANDROID_NDK_HOME}")
endif()

if(NOT DEFINED ENV{SWIFT_ANDROID_ABI} OR "$ENV{SWIFT_ANDROID_ABI}" STREQUAL "")
    message(FATAL_ERROR "SWIFT_ANDROID_ABI must be defined")
endif()

if(NOT DEFINED ENV{SWIFT_ANDROID_ARCH} OR "$ENV{SWIFT_ANDROID_ARCH}" STREQUAL "")
    message(FATAL_ERROR "SWIFT_ANDROID_ARCH must be defined")
endif()
if(NOT "$ENV{SWIFT_ANDROID_ARCH}" MATCHES "^(aarch64|x86_64|armv7)$")
    message(FATAL_ERROR "SWIFT_ANDROID_ARCH must be one of: aarch64, x86_64, armv7")
endif()

if(NOT DEFINED ENV{SWIFT_ANDROID_API_LEVEL} OR "$ENV{SWIFT_ANDROID_API_LEVEL}" STREQUAL "")
    message(FATAL_ERROR "SWIFT_ANDROID_API_LEVEL must be defined")
endif()
if(NOT "$ENV{SWIFT_ANDROID_API_LEVEL}" MATCHES "^[0-9]+$")
    message(FATAL_ERROR "SWIFT_ANDROID_API_LEVEL must be numeric")
endif()
if($ENV{SWIFT_ANDROID_API_LEVEL} LESS 28)
    message(FATAL_ERROR "SWIFT_ANDROID_API_LEVEL must be >= 28")
endif()

if(NOT DEFINED ENV{SWIFT_ANDROID_VERSION} OR "$ENV{SWIFT_ANDROID_VERSION}" STREQUAL "")
    message(FATAL_ERROR "SWIFT_ANDROID_VERSION must be defined")
endif()

# Start from the official NDK toolchain
set(ANDROID_ABI $ENV{SWIFT_ANDROID_ABI})
set(ANDROID_NATIVE_API_LEVEL $ENV{SWIFT_ANDROID_API_LEVEL})
include("$ENV{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/android-post.toolchain.cmake")

# Infer from Swift Android SDK version, arch, and API level
set(SWIFT_ANDROID_SDK $ENV{HOME}/.swiftpm/swift-sdks/swift-$ENV{SWIFT_ANDROID_VERSION}-RELEASE_android.artifactbundle)
set(SWIFT_ANDROID_TRIPLE "$ENV{SWIFT_ANDROID_ARCH}-unknown-linux-android${ANDROID_NATIVE_API_LEVEL}")
set(SWIFT_RESOURCE_DIR "${SWIFT_ANDROID_SDK}/swift-android/swift-resources/usr/lib/swift_static-$ENV{SWIFT_ANDROID_ARCH}")
if(NOT IS_DIRECTORY "${SWIFT_ANDROID_SDK}")
    message(FATAL_ERROR "SWIFT_ANDROID_SDK must point to an existing directory: ${SWIFT_ANDROID_SDK}")
endif()
if(NOT IS_DIRECTORY "${SWIFT_RESOURCE_DIR}")
    message(FATAL_ERROR "SWIFT_RESOURCE_DIR must point to an existing directory: ${SWIFT_RESOURCE_DIR}")
endif()

# Compiler flags
set(CMAKE_C_COMPILER_TARGET ${SWIFT_ANDROID_TRIPLE})
set(CMAKE_CXX_COMPILER_TARGET ${SWIFT_ANDROID_TRIPLE})
set(CMAKE_Swift_COMPILER_TARGET ${SWIFT_ANDROID_TRIPLE})

# Inherit clang resource dir (e.g. for stddef.h and stdbool.h)
execute_process(
    COMMAND "${ANDROID_TOOLCHAIN_ROOT}/bin/clang" -print-resource-dir
    OUTPUT_VARIABLE ANDROID_CLANG_RESOURCE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if(NOT ANDROID_CLANG_RESOURCE_DIR)
    message(FATAL_ERROR "Unable to infer Android clang resource directory")
endif()
if(NOT IS_DIRECTORY "${ANDROID_CLANG_RESOURCE_DIR}")
    message(FATAL_ERROR "ANDROID_CLANG_RESOURCE_DIR must point to an existing directory: ${ANDROID_CLANG_RESOURCE_DIR}")
endif()

# C/C++
set(CMAKE_C_FLAGS "-fPIC")

# Swift
set(CMAKE_Swift_COMPILER ${CMAKE_CURRENT_LIST_DIR}/swiftc-wrapper.sh)
set(CMAKE_Swift_FLAGS "\
    -target ${SWIFT_ANDROID_TRIPLE} \
    -resource-dir ${SWIFT_RESOURCE_DIR} \
    -Xcc -resource-dir -Xcc ${ANDROID_CLANG_RESOURCE_DIR} \
    -tools-directory ${ANDROID_TOOLCHAIN_ROOT}/bin \
    -sdk ${SWIFT_ANDROID_SDK}/swift-android/ndk-sysroot \
    -module-cache-path ${CMAKE_BINARY_DIR}/swift-module-cache \
    -lFoundationEssentials \
    -l_FoundationCollections \
    -l_FoundationCShims \
    -lswiftSynchronization \
    -landroid \
    -lc++_shared \
    -llog \
    -lm"
)

set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
