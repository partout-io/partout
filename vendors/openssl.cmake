set(OPENSSL_DIR ${PP_BUILD_OUTPUT}/openssl)

# Use nmake on Windows
if(WIN32)
    set(OPENSSL_BUILD_CMD nmake)
else()
    set(OPENSSL_BUILD_CMD make)
endif()

# Configure flags
set(OPENSSL_CFG_FLAGS no-apps no-docs no-dsa no-engine no-gost no-legacy shared no-ssl no-tests no-zlib)

# Add some flags if -DANDROID (requires NDK tools in the PATH)
if(ANDROID)
    set(OPENSSL_TARGET "android-arm64")
    set(OPENSSL_SYMBOLS "-D__ANDROID_API__=${CMAKE_SYSTEM_VERSION}")
else()
    set(OPENSSL_TARGET "")
    set(OPENSSL_SYMBOLS "")
endif()

set(CFG_ARGS
    ${OPENSSL_TARGET}
    --prefix=${OPENSSL_DIR}
    --openssldir=${OPENSSL_DIR}
    ${OPENSSL_SYMBOLS}
    ${OPENSSL_CFG_FLAGS}
)
ExternalProject_Add(OpenSSLProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/openssl
    CONFIGURE_COMMAND perl ${CMAKE_CURRENT_SOURCE_DIR}/vendors/openssl/Configure ${CFG_ARGS}
    BUILD_COMMAND ${OPENSSL_BUILD_CMD}
    INSTALL_COMMAND ${OPENSSL_BUILD_CMD} install
)

if(APPLE)
    add_custom_command(
        TARGET OpenSSLProject
        POST_BUILD
        COMMAND install_name_tool -id "@rpath/libcrypto.3.dylib" "${OPENSSL_DIR}/lib/libcrypto.3.dylib"
        COMMAND install_name_tool -id "@rpath/libssl.3.dylib" "${OPENSSL_DIR}/lib/libssl.3.dylib"
        COMMAND install_name_tool -change
            "${OPENSSL_DIR}/lib/libcrypto.3.dylib"
            "@rpath/libcrypto.3.dylib"
            "${OPENSSL_DIR}/lib/libssl.3.dylib"
    )
endif()

add_library(OpenSSLInterface INTERFACE)
add_dependencies(OpenSSLInterface OpenSSLProject)
target_include_directories(OpenSSLInterface INTERFACE ${OPENSSL_DIR}/include)
if(WIN32)
    target_link_libraries(OpenSSLInterface INTERFACE
        ${OPENSSL_DIR}/lib/libssl.lib
        ${OPENSSL_DIR}/lib/libcrypto.lib
    )
else()
    target_link_directories(OpenSSLInterface INTERFACE ${OPENSSL_DIR}/lib)
    target_link_libraries(OpenSSLInterface INTERFACE ssl crypto)
endif()
