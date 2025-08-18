cmake_minimum_required(VERSION 3.27)
project(Partout)
include(ExternalProject)

set(ALL_CMAKE_ARGS)

include("vendors/openssl.cmake")
ExternalProject_Get_Property(OpenSSLProject BINARY_DIR)
list(APPEND ALL_CMAKE_ARGS -DOPENSSL_DIR=${OPENSSL_OUTPUT_DIR})

# include("vendors/mbedtls.cmake")
# ExternalProject_Get_Property(mbedTLSProject BINARY_DIR)
# list(APPEND ALL_CMAKE_ARGS -DMBEDTLS_DIR=${MBEDTLS_OUTPUT_DIR})

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
