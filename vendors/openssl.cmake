set(OPENSSL_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/bin/openssl)
set(CFG_ARGS
    --prefix=${OPENSSL_OUTPUT_DIR}
    --openssldir=${OPENSSL_OUTPUT_DIR}
    no-apps no-docs no-engine no-gost no-legacy no-shared no-tests no-zlib
)
ExternalProject_Add(
    OpenSSLProject
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendors/openssl
    CONFIGURE_COMMAND ${CMAKE_SOURCE_DIR}/vendors/openssl/Configure ${CFG_ARGS}
    BUILD_COMMAND make -j8
    INSTALL_COMMAND make install
    #BUILD_BYPRODUCTS ${CMAKE_BINARY_DIR}/libcrypto.a ${CMAKE_BINARY_DIR}/libssl.a
)
