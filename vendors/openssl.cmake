set(PARTOUT_OPENSSL_DEPENDENCY "")

if(PP_USE_SYSTEM_VENDORS)
    partout_use_homebrew_formula(openssl@3.5)
    find_package(OpenSSL 3 REQUIRED COMPONENTS SSL Crypto)

    set(PARTOUT_OPENSSL_INCLUDE_DIR "${OPENSSL_INCLUDE_DIR}")
    get_filename_component(PARTOUT_OPENSSL_LIBRARY_DIR "${OPENSSL_SSL_LIBRARY}" DIRECTORY)
    if(CMAKE_LIBRARY_ARCHITECTURE AND
       EXISTS "/usr/include/${CMAKE_LIBRARY_ARCHITECTURE}/openssl/opensslconf.h")
        set(PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR "/usr/include/${CMAKE_LIBRARY_ARCHITECTURE}")
    endif()

    message(STATUS "Using system OpenSSL")
    return()
endif()

set(OPENSSL_DIR "${PP_BUILD_OUTPUT}/openssl")
set(PARTOUT_OPENSSL_INCLUDE_DIR "${OPENSSL_DIR}/include")
set(PARTOUT_OPENSSL_LIBRARY_DIR "${OPENSSL_DIR}/lib")

if(PP_USE_PREBUILT_VENDORS)
    partout_use_prebuilt_vendor(openssl OPENSSL_DIR)
    return()
endif()

set(OPENSSL_TARGET "" CACHE STRING "OpenSSL Configure target")
set(OPENSSL_PLATFORM_ARGS "" CACHE STRING "Additional OpenSSL Configure arguments")
set(OPENSSL_ENV ${VENDOR_ENV})
if(NOT OPENSSL_TARGET)
    if(WIN32)
        if(ARCH_NAME MATCHES "^(arm64|aarch64)$")
            set(OPENSSL_TARGET VC-WIN64-ARM)
        else()
            set(OPENSSL_TARGET VC-WIN64A)
        endif()
    elseif(ANDROID)
        set(OPENSSL_TARGET android-arm64)
    endif()
endif()

if(ANDROID)
    list(APPEND OPENSSL_ENV "ANDROID_NDK_ROOT=${CMAKE_ANDROID_NDK}")
elseif(APPLE)
    set(OPENSSL_ENV
        "${CMAKE_COMMAND}" -E env
        "CFLAGS=-isysroot ${CMAKE_OSX_SYSROOT} -target ${CMAKE_C_COMPILER_TARGET}"
        "LDFLAGS=-isysroot ${CMAKE_OSX_SYSROOT} -target ${CMAKE_C_COMPILER_TARGET}"
    )
endif()

set(OPENSSL_CONFIGURE_ARGS
    ${OPENSSL_TARGET}
    ${OPENSSL_PLATFORM_ARGS}
    "--prefix=${OPENSSL_DIR}"
    "--openssldir=${OPENSSL_DIR}"
    --libdir=lib
    no-apps
    no-docs
    no-dsa
    no-engine
    no-gost
    no-legacy
    shared
    no-ssl
    no-tests
    no-zlib
)

set(OPENSSL_BUILD_COMMAND ${OPENSSL_ENV} ${MAKE_CMD})
if(NOT WIN32)
    include(ProcessorCount)
    ProcessorCount(OPENSSL_BUILD_JOBS)
    if(OPENSSL_BUILD_JOBS)
        list(APPEND OPENSSL_BUILD_COMMAND "-j${OPENSSL_BUILD_JOBS}")
    endif()
endif()

set(OPENSSL_INSTALL_COMMAND ${OPENSSL_ENV} ${MAKE_CMD} install_sw)
if(APPLE)
    list(APPEND OPENSSL_INSTALL_COMMAND
        COMMAND install_name_tool -id @rpath/libcrypto.3.dylib "${OPENSSL_DIR}/lib/libcrypto.3.dylib"
        COMMAND install_name_tool -id @rpath/libssl.3.dylib "${OPENSSL_DIR}/lib/libssl.3.dylib"
        COMMAND install_name_tool -change
            "${OPENSSL_DIR}/lib/libcrypto.3.dylib"
            @rpath/libcrypto.3.dylib
            "${OPENSSL_DIR}/lib/libssl.3.dylib"
    )
endif()

set(OPENSSL_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendors/openssl")
set(OPENSSL_BUILD_SOURCE_DIR "${CMAKE_CURRENT_BINARY_DIR}/vendors/openssl-src")
ExternalProject_Add(OpenSSLProject
    SOURCE_DIR "${OPENSSL_BUILD_SOURCE_DIR}"
    DOWNLOAD_COMMAND
        "${CMAKE_COMMAND}" -E rm -rf "${OPENSSL_BUILD_SOURCE_DIR}"
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${OPENSSL_SOURCE_DIR}" "${OPENSSL_BUILD_SOURCE_DIR}"
    CONFIGURE_COMMAND ${OPENSSL_ENV} perl "${OPENSSL_BUILD_SOURCE_DIR}/Configure" ${OPENSSL_CONFIGURE_ARGS}
    BUILD_COMMAND ${OPENSSL_BUILD_COMMAND}
    INSTALL_COMMAND ${OPENSSL_INSTALL_COMMAND}
    BUILD_IN_SOURCE 1
)
set(PARTOUT_OPENSSL_DEPENDENCY OpenSSLProject)
