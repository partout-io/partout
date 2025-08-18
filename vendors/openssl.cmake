set(OPENSSL_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/bin/openssl)

# Use nmake on Windows
if (WIN32)
    set(OPENSSL_BUILD_CMD nmake)
    set(OPENSSL_BUILD_IN_SOURCE TRUE)
else()
    set(OPENSSL_BUILD_CMD make)
    set(OPENSSL_BUILD_IN_SOURCE FALSE)
endif()

set(CFG_ARGS
    --prefix=${OPENSSL_OUTPUT_DIR}
    --openssldir=${OPENSSL_OUTPUT_DIR}
    no-apps no-docs no-engine no-gost no-legacy no-shared no-tests no-zlib
)
ExternalProject_Add(
    OpenSSLProject
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendors/openssl
    CONFIGURE_COMMAND perl ${CMAKE_SOURCE_DIR}/vendors/openssl/Configure ${CFG_ARGS}
    BUILD_COMMAND ${OPENSSL_BUILD_CMD}
    INSTALL_COMMAND ${OPENSSL_BUILD_CMD} install
    BUILD_IN_SOURCE ${OPENSSL_BUILD_IN_SOURCE}
    #BUILD_BYPRODUCTS ${CMAKE_BINARY_DIR}/libcrypto.a ${CMAKE_BINARY_DIR}/libssl.a
)
