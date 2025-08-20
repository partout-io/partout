set(OPENSSL_OUTPUT_DIR ${CMAKE_SOURCE_DIR}/${PP_BUILD_OUTPUT}/openssl)

# Use nmake on Windows
if(WIN32)
    set(OPENSSL_BUILD_CMD nmake)
else()
    set(OPENSSL_BUILD_CMD make)
endif()

# Configure flags
set(OPENSSL_CFG_FLAGS no-apps no-docs no-dsa no-engine no-gost no-legacy no-shared no-ssl no-tests no-zlib)

# Add some flags if -DANDROID (requires NDK tools in the PATH)
if(PP_BUILD_FOR_ANDROID)
    set(OPENSSL_TARGET "android-arm64")
    set(OPENSSL_SYMBOLS "-D__ANDROID_API__=24")
else()
    set(OPENSSL_TARGET "")
    set(OPENSSL_SYMBOLS "")
endif()

set(CFG_ARGS
    ${OPENSSL_TARGET}
    --prefix=${OPENSSL_OUTPUT_DIR}
    --openssldir=${OPENSSL_OUTPUT_DIR}
    ${OPENSSL_SYMBOLS}
    ${OPENSSL_CFG_FLAGS}
)
ExternalProject_Add(
    OpenSSLProject
    SOURCE_DIR ${CMAKE_SOURCE_DIR}/vendors/openssl
    CONFIGURE_COMMAND perl ${CMAKE_SOURCE_DIR}/vendors/openssl/Configure ${CFG_ARGS}
    BUILD_COMMAND ${OPENSSL_BUILD_CMD}
    INSTALL_COMMAND ${OPENSSL_BUILD_CMD} install
    #BUILD_BYPRODUCTS ${CMAKE_BINARY_DIR}/libcrypto.a ${CMAKE_BINARY_DIR}/libssl.a
)
