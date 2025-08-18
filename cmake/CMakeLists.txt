cmake_minimum_required(VERSION 3.27)
project(PartoutProject LANGUAGES Swift C CXX)

set(PARTOUT_DIR ${CMAKE_SOURCE_DIR}/..)

include(partout-core.cmake)
include(partout-c.cmake)
include(partout.cmake)

# Output to root
set_target_properties(Partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${PARTOUT_DIR}/bin
    ARCHIVE_OUTPUT_DIRECTORY ${PARTOUT_DIR}/bin
)

# Link to vendor-specific dependencies
if (DEFINED OPENSSL_DIR)
    target_include_directories(Partout_C PRIVATE
        ${PARTOUT_DIR}/Sources/Crypto/CryptoOpenSSL_C/include
        ${PARTOUT_DIR}/Sources/Crypto/TLSOpenSSL_C/include
        ${OPENSSL_DIR}/include
    )
    target_link_libraries(Partout_C PRIVATE
        ${OPENSSL_DIR}/lib/libssl.a
        ${OPENSSL_DIR}/lib/libcrypto.a
    )
endif()
if (DEFINED MBEDTLS_DIR)
    target_include_directories(Partout_C PRIVATE
        ${PARTOUT_DIR}/Sources/Crypto/CryptoMbedTLS_C/include
        ${PARTOUT_DIR}/Sources/Crypto/TLSMbedTLS_C/include
        ${MBEDTLS_DIR}/include
    )
    target_link_libraries(Partout_C PRIVATE
        ${MBEDTLS_DIR}/lib/libmbedcrypto.a
        ${MBEDTLS_DIR}/lib/libmbedtls.a
        ${MBEDTLS_DIR}/lib/libmbedx509.a
    )
endif()
