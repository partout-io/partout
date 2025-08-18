cmake_minimum_required(VERSION 3.27)
project(Partout)
include(ExternalProject)

# Command line options
option(BUILD_LIBRARY "Include main library" 0)
option(BUILD_FOR_ANDROID "Build for Android" 0)
# message(STATUS "CMAKE_BUILD_TYPE = ${CMAKE_BUILD_TYPE}")
# message(STATUS "BUILD_LIBRARY = ${BUILD_LIBRARY}")
# message(STATUS "BUILD_FOR_ANDROID = ${BUILD_FOR_ANDROID}")
# message(FATAL_ERROR "STOP")

# All vendor-inherited args
set(ALL_CMAKE_ARGS)

include("vendors/openssl.cmake")
ExternalProject_Get_Property(OpenSSLProject BINARY_DIR)
list(APPEND ALL_CMAKE_ARGS -DOPENSSL_DIR=${OPENSSL_OUTPUT_DIR})

# include("vendors/mbedtls.cmake")
# ExternalProject_Get_Property(mbedTLSProject BINARY_DIR)
# list(APPEND ALL_CMAKE_ARGS -DMBEDTLS_DIR=${MBEDTLS_OUTPUT_DIR})

# Build Partout, unless -DVENDORS_ONLY
if(BUILD_LIBRARY)

    # Bundle library with ABI header
    set(PARTOUT_ABI_HEADER ${CMAKE_SOURCE_DIR}/Sources/ABI/Library_C/include/partout.h)

    ExternalProject_Add(
        PartoutProject
        SOURCE_DIR ${CMAKE_SOURCE_DIR}/cmake
        CMAKE_ARGS ${ALL_CMAKE_ARGS}
        INSTALL_COMMAND ""
        COMMAND ${CMAKE_COMMAND} -E copy ${PARTOUT_ABI_HEADER} ${CMAKE_SOURCE_DIR}/bin
        DEPENDS OpenSSLProject
        #DEPENDS mbedTLSProject
    )
endif()
