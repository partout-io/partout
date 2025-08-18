set(MBEDTLS_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/bin/mbedtls)
ExternalProject_Add(
    mbedTLSProject
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendors/mbedtls
    CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${MBEDTLS_OUTPUT_DIR}
)
