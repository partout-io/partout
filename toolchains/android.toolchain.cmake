# From environment
# ANDROID_NDK_HOME
# SWIFT_ANDROID_ABI
# SWIFT_ANDROID_ARCH
# SWIFT_ANDROID_API_LEVEL
# SWIFT_ANDROID_VERSION

# Start from the official NDK toolchain
set(ANDROID_ABI $ENV{SWIFT_ANDROID_ABI})
set(ANDROID_NATIVE_API_LEVEL $ENV{SWIFT_ANDROID_API_LEVEL})
set(ANDROID_USE_LEGACY_TOOLCHAIN_FILE FALSE)
include("$ENV{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake")

# Infer from Swift Android SDK version, arch, and API level
set(SWIFT_ANDROID_SDK $ENV{HOME}/.swiftpm/swift-sdks/swift-$ENV{SWIFT_ANDROID_VERSION}-RELEASE_android.artifactbundle)
set(SWIFT_ANDROID_TRIPLE "$ENV{SWIFT_ANDROID_ARCH}-unknown-linux-android${ANDROID_NATIVE_API_LEVEL}")
set(SWIFT_RESOURCE_DIR "${SWIFT_ANDROID_SDK}/swift-android/swift-resources/usr/lib/swift_static-$ENV{SWIFT_ANDROID_ARCH}")

# Compiler flags
set(CMAKE_C_COMPILER_TARGET ${SWIFT_ANDROID_TRIPLE})
set(CMAKE_CXX_COMPILER_TARGET ${SWIFT_ANDROID_TRIPLE})
set(CMAKE_Swift_COMPILER_TARGET ${SWIFT_ANDROID_TRIPLE})

# Inherit clang resource dir (e.g. for stddef.h and stdbool.h)
execute_process(
    COMMAND "${CMAKE_C_COMPILER}" -print-resource-dir
    OUTPUT_VARIABLE ANDROID_CLANG_RESOURCE_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)

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
    -lFoundationEssentials \
    -l_FoundationCollections \
    -l_FoundationCShims \
    -lswiftSynchronization \
    -lc++_shared \
    -llog \
    -lm"
)

set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
