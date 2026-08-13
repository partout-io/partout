set(PARTOUT_ZIG_ARGS build install
    --prefix "${PP_BUILD_OUTPUT}/partout"
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    "-Dshared=$<IF:$<BOOL:${PP_BUILD_STATIC}>,false,true>"
)

if(PP_BUILD_USE_OPENSSL)
    set(PARTOUT_OPENSSL_IS_PREBUILT OFF)
    if(PP_SYSTEM_VENDORS_AVAILABLE)
        partout_use_homebrew_formula(openssl@3.5)
        find_package(OpenSSL 3 QUIET COMPONENTS SSL Crypto)
    endif()
    if(PP_SYSTEM_VENDORS_AVAILABLE AND OpenSSL_FOUND)
        set(PARTOUT_OPENSSL_INCLUDE_DIR "${OPENSSL_INCLUDE_DIR}")
        get_filename_component(PARTOUT_OPENSSL_LIBRARY_DIR
            "${OPENSSL_SSL_LIBRARY}" DIRECTORY)
        if(CMAKE_LIBRARY_ARCHITECTURE AND
           EXISTS "/usr/include/${CMAKE_LIBRARY_ARCHITECTURE}/openssl/opensslconf.h")
            set(PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR
                "/usr/include/${CMAKE_LIBRARY_ARCHITECTURE}")
        endif()
        message(STATUS "Using system OpenSSL")
    else()
        partout_use_prebuilt_vendor(openssl OPENSSL_DIR)
        set(PARTOUT_OPENSSL_IS_PREBUILT ON)
        set(PARTOUT_OPENSSL_INCLUDE_DIR "${OPENSSL_DIR}/include")
        set(PARTOUT_OPENSSL_LIBRARY_DIR "${OPENSSL_DIR}/lib")
    endif()
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dopenssl-include=${PARTOUT_OPENSSL_INCLUDE_DIR}"
        "-Dopenssl-lib=${PARTOUT_OPENSSL_LIBRARY_DIR}"
    )
    if(PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR)
        list(APPEND PARTOUT_ZIG_ARGS
            "-Dopenssl-config-include=${PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR}"
        )
    endif()
endif()

if(PP_BUILD_USE_MBEDTLS)
    set(PARTOUT_MBEDTLS_IS_PREBUILT OFF)
    if(PP_SYSTEM_VENDORS_AVAILABLE)
        partout_use_homebrew_formula(mbedtls)
        find_path(PARTOUT_MBEDTLS_INCLUDE_DIR mbedtls/ssl.h)
        find_library(PARTOUT_MBEDTLS_TLS_LIBRARY mbedtls)
        find_library(PARTOUT_MBEDTLS_X509_LIBRARY mbedx509)
        find_library(PARTOUT_MBEDTLS_CRYPTO_LIBRARY mbedcrypto)
    endif()
    if(PP_SYSTEM_VENDORS_AVAILABLE AND PARTOUT_MBEDTLS_INCLUDE_DIR AND
       PARTOUT_MBEDTLS_TLS_LIBRARY AND PARTOUT_MBEDTLS_X509_LIBRARY AND
       PARTOUT_MBEDTLS_CRYPTO_LIBRARY)
        get_filename_component(PARTOUT_MBEDTLS_LIBRARY_DIR
            "${PARTOUT_MBEDTLS_TLS_LIBRARY}" DIRECTORY)
        message(STATUS "Using system MbedTLS")
    else()
        partout_use_prebuilt_vendor(mbedtls MBEDTLS_DIR)
        set(PARTOUT_MBEDTLS_IS_PREBUILT ON)
        set(PARTOUT_MBEDTLS_INCLUDE_DIR "${MBEDTLS_DIR}/include")
        set(PARTOUT_MBEDTLS_LIBRARY_DIR "${MBEDTLS_DIR}/lib")
    endif()
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dmbedtls-include=${PARTOUT_MBEDTLS_INCLUDE_DIR}"
        "-Dmbedtls-lib=${PARTOUT_MBEDTLS_LIBRARY_DIR}"
    )
endif()

if(PP_BUILD_USE_OPENVPN)
    list(APPEND PARTOUT_ZIG_ARGS -Dopenvpn=true)
endif()

if(PP_BUILD_USE_WIREGUARD)
    if(PP_SYSTEM_VENDORS_AVAILABLE)
        find_path(PARTOUT_WGGO_INCLUDE_DIR wg_go/wg_go.h)
        find_library(PARTOUT_WGGO_LIBRARY wg-go)
    endif()
    if(PP_SYSTEM_VENDORS_AVAILABLE AND PARTOUT_WGGO_INCLUDE_DIR AND
       PARTOUT_WGGO_LIBRARY)
        get_filename_component(PARTOUT_WGGO_LIBRARY_DIR
            "${PARTOUT_WGGO_LIBRARY}" DIRECTORY)
        set(WGGO_RUNTIME_LIBRARY "${PARTOUT_WGGO_LIBRARY}")
        message(STATUS "Using system wg-go")
    else()
        partout_use_prebuilt_vendor(wg-go WGGO_DIR)
        set(PARTOUT_WGGO_INCLUDE_DIR "${WGGO_DIR}/include")
        set(PARTOUT_WGGO_LIBRARY_DIR "${WGGO_DIR}/lib")
        if(WIN32)
            set(WGGO_RUNTIME_LIBRARY "${WGGO_DIR}/lib/wg-go.dll")
        elseif(APPLE)
            set(WGGO_RUNTIME_LIBRARY "${WGGO_DIR}/lib/libwg-go.a")
        else()
            set(WGGO_RUNTIME_LIBRARY "${WGGO_DIR}/lib/libwg-go.so")
        endif()
    endif()
    list(APPEND PARTOUT_ZIG_ARGS
        -Dwireguard=true
        "-Dwg-go-include=${PARTOUT_WGGO_INCLUDE_DIR}"
        "-Dwg-go-lib=${PARTOUT_WGGO_LIBRARY_DIR}"
    )
endif()

if(WIN32 AND PP_BUILD_LIBRARY)
    include("${CMAKE_CURRENT_LIST_DIR}/wintun.cmake")
    list(APPEND PARTOUT_ZIG_ARGS "-Dwintun-include=${WINTUN_DIR}")
endif()

set(PARTOUT_ZIG_ARCH "${ARCH_NAME}")
if(PARTOUT_ZIG_ARCH MATCHES "^(arm64|aarch64)$")
    set(PARTOUT_ZIG_ARCH aarch64)
elseif(PARTOUT_ZIG_ARCH MATCHES "^(x64|x86_64|amd64)$")
    set(PARTOUT_ZIG_ARCH x86_64)
endif()

if(ANDROID)
    string(REGEX REPLACE "^android-" "" PARTOUT_ANDROID_API "${ANDROID_PLATFORM}")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-android.${PARTOUT_ANDROID_API}")
    set(PARTOUT_ZIG_LIBC "${CMAKE_CURRENT_BINARY_DIR}/android.libc")
    file(WRITE "${PARTOUT_ZIG_LIBC}"
"include_dir=${CMAKE_SYSROOT}/usr/include
sys_include_dir=${CMAKE_SYSROOT}/usr/include/${CMAKE_LIBRARY_ARCHITECTURE}
crt_dir=${CMAKE_SYSROOT}/usr/lib/${CMAKE_LIBRARY_ARCHITECTURE}/${PARTOUT_ANDROID_API}
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
")
    list(APPEND PARTOUT_ZIG_ARGS --libc "${PARTOUT_ZIG_LIBC}")
elseif(APPLE)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-macos")
    if(IS_DIRECTORY "${CMAKE_OSX_SYSROOT}")
        set(PARTOUT_APPLE_SDK "${CMAKE_OSX_SYSROOT}")
    else()
        execute_process(
            COMMAND xcrun --sdk macosx --show-sdk-path
            OUTPUT_VARIABLE PARTOUT_APPLE_SDK
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
    endif()
    if(PARTOUT_APPLE_SDK)
        list(APPEND PARTOUT_ZIG_ARGS "-Dapple-sdk-path=${PARTOUT_APPLE_SDK}")
    endif()
elseif(WIN32)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-windows-msvc")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-gnu")
endif()
if(PARTOUT_ZIG_TARGET)
    list(APPEND PARTOUT_ZIG_ARGS "-Dtarget=${PARTOUT_ZIG_TARGET}")
endif()

if(PP_BUILD_LIBRARY)
    find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)
    add_custom_target(partout ALL
        COMMAND "${PARTOUT_ZIG_EXECUTABLE}" ${PARTOUT_ZIG_ARGS}
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        USES_TERMINAL
        COMMAND_EXPAND_LISTS
        VERBATIM
    )
endif()
