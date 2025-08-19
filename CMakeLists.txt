cmake_minimum_required(VERSION 3.27)
project(Partout)
include(ExternalProject)

# Command line options
option(PP_BUILD_LIBRARY "Include main library" 0)
option(PP_BUILD_FOR_ANDROID "Build for Android" 0)
option(PP_BUILD_USE_OPENSSL "Use OpenSSL" 1)
option(PP_BUILD_USE_MBEDTLS "Use mbedTLS" 0)

# Output per platform/arch
if(PP_BUILD_FOR_ANDROID)
    set(PLATFORM_NAME "android")
else()
    set(PLATFORM_NAME ${CMAKE_SYSTEM_NAME})
    string(TOLOWER ${PLATFORM_NAME} PLATFORM_NAME)
endif()
set(ARCH_NAME ${CMAKE_SYSTEM_PROCESSOR})
string(TOLOWER ${ARCH_NAME} ARCH_NAME)
set(PP_BUILD_OUTPUT_UNIVERSAL "bin")
set(PP_BUILD_OUTPUT "${PP_BUILD_OUTPUT_UNIVERSAL}/${PLATFORM_NAME}-${ARCH_NAME}")

# Options
message(STATUS "Option CMAKE_BUILD_TYPE = ${CMAKE_BUILD_TYPE}")
message(STATUS "Option PP_BUILD_LIBRARY = ${PP_BUILD_LIBRARY}")
message(STATUS "Option PP_BUILD_USE_OPENSSL = ${PP_BUILD_USE_OPENSSL}")
message(STATUS "Option PP_BUILD_USE_MBEDTLS = ${PP_BUILD_USE_MBEDTLS}")
message(STATUS "Option PP_BUILD_FOR_ANDROID = ${PP_BUILD_FOR_ANDROID}")
message(STATUS "Option PP_BUILD_OUTPUT = ${PP_BUILD_OUTPUT}")

# Forward args to Partout sub-project
set(PARTOUT_CMAKE_ARGS -DPP_BUILD_OUTPUT=${PP_BUILD_OUTPUT})

# All vendor-inherited args
set(VENDOR_CRYPTO_DEPENDS)
if(PP_BUILD_USE_OPENSSL)
    include("vendors/openssl.cmake")
    ExternalProject_Get_Property(OpenSSLProject BINARY_DIR)
    set(VENDOR_CRYPTO_DEPENDS OpenSSLProject)
    list(APPEND PARTOUT_CMAKE_ARGS -DOPENSSL_DIR=${OPENSSL_OUTPUT_DIR})
endif()
if(PP_BUILD_USE_MBEDTLS)
    include("vendors/mbedtls.cmake")
    ExternalProject_Get_Property(mbedTLSProject BINARY_DIR)
    set(VENDOR_CRYPTO_DEPENDS mbedTLSProject)
    list(APPEND PARTOUT_CMAKE_ARGS -DMBEDTLS_DIR=${MBEDTLS_OUTPUT_DIR})
endif()

# Build Partout library (opt-in), after vendored dependencies
if(PP_BUILD_LIBRARY)

    # Bundle library with ABI header
    set(PARTOUT_ABI_HEADER ${CMAKE_SOURCE_DIR}/Sources/ABI/Library_C/include/partout.h)

    ExternalProject_Add(
        PartoutProject
        SOURCE_DIR ${CMAKE_SOURCE_DIR}/cmake
        CMAKE_ARGS ${PARTOUT_CMAKE_ARGS}
        INSTALL_COMMAND ""
        COMMAND ${CMAKE_COMMAND} -E copy ${PARTOUT_ABI_HEADER} ${CMAKE_SOURCE_DIR}/${PP_BUILD_OUTPUT_UNIVERSAL}
        DEPENDS ${VENDOR_CRYPTO_DEPENDS}
    )
endif()
