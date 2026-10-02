set(PARTOUT_ZIG_ARGS build install
    --prefix "${PP_BUILD_OUTPUT}/partout"
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    "-Dstrip=$<IF:$<CONFIG:Debug,RelWithDebInfo>,false,true>"
    "-Dshared=$<IF:$<BOOL:${APPLE}>,false,true>"
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
        if(NOT APPLE)
            include("${OPENSSL_DIR}/lib/cmake/OpenSSL/OpenSSLConfig.cmake")
            set_property(TARGET OpenSSL::SSL PROPERTY IMPORTED_GLOBAL TRUE)
            set_property(TARGET OpenSSL::Crypto PROPERTY IMPORTED_GLOBAL TRUE)
            list(APPEND PARTOUT_RUNTIME_LIBRARIES
                OpenSSL::SSL OpenSSL::Crypto)
        endif()
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
        if(NOT APPLE)
            include("${MBEDTLS_DIR}/lib/cmake/MbedTLS/MbedTLSConfig.cmake")
            foreach(target mbedtls mbedx509 tfpsacrypto)
                set_property(TARGET MbedTLS::${target}
                    PROPERTY IMPORTED_GLOBAL TRUE)
            endforeach()
        endif()
    endif()
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dmbedtls-include=${PARTOUT_MBEDTLS_INCLUDE_DIR}"
        "-Dmbedtls-lib=${PARTOUT_MBEDTLS_LIBRARY_DIR}"
    )
endif()

if(APPLE)
    # CMake's native linker combines the Zig archive and enabled backends.
    if(PP_BUILD_USE_OPENSSL)
        if(PARTOUT_OPENSSL_IS_PREBUILT)
            list(APPEND PARTOUT_APPLE_LIBRARIES "${OPENSSL_DIR}/lib/libopenssl.a")
        else()
            list(APPEND PARTOUT_APPLE_LIBRARIES "${OPENSSL_SSL_LIBRARY}" "${OPENSSL_CRYPTO_LIBRARY}")
        endif()
    endif()
    if(PP_BUILD_USE_MBEDTLS)
        if(PARTOUT_MBEDTLS_IS_PREBUILT)
            list(APPEND PARTOUT_APPLE_LIBRARIES "${MBEDTLS_DIR}/lib/libmbedtls.a")
        else()
            list(APPEND PARTOUT_APPLE_LIBRARIES "${PARTOUT_MBEDTLS_TLS_LIBRARY}"
                "${PARTOUT_MBEDTLS_X509_LIBRARY}" "${PARTOUT_MBEDTLS_CRYPTO_LIBRARY}")
        endif()
    endif()
endif()

if(PP_BUILD_USE_OPENVPN)
    list(APPEND PARTOUT_ZIG_ARGS -Dopenvpn=true)
endif()

if(PP_BUILD_USE_WIREGUARD)
    include("${CMAKE_CURRENT_LIST_DIR}/wg-go.cmake")
    list(APPEND PARTOUT_ZIG_ARGS
        -Dwireguard=true
        "-Dwg-go-include=${wg_source}/include"
        "-Dwg-go-lib=${wg_work}/lib"
    )
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
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(PARTOUT_APPLE_OS ios)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "tvOS")
        set(PARTOUT_APPLE_OS tvos)
    else()
        set(PARTOUT_APPLE_OS macos)
    endif()
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-${PARTOUT_APPLE_OS}")
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        string(APPEND PARTOUT_ZIG_TARGET ".${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        string(APPEND PARTOUT_ZIG_TARGET "-simulator")
    endif()
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
    if(PP_BUILD_WINRT)
        list(APPEND PARTOUT_ZIG_ARGS "-Dwinrt-lib=$<TARGET_FILE:partout-winrt>")
    endif()
    find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)
    if(WIN32)
        set(PARTOUT_LINK_LIBRARY "${PP_BUILD_OUTPUT}/partout/lib/partout.lib")
        set(PARTOUT_ZIG_BYPRODUCTS
            "${PARTOUT_LINK_LIBRARY}"
            "${PP_BUILD_OUTPUT}/partout/bin/partout.dll"
        )
    else()
        set(PARTOUT_LINK_LIBRARY
            "${PP_BUILD_OUTPUT}/partout/lib/${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}")
        set(PARTOUT_ZIG_BYPRODUCTS "${PARTOUT_LINK_LIBRARY}")
    endif()

    set(PARTOUT_COMPILE_TARGET partout)
    if(APPLE)
        set(PARTOUT_COMPILE_TARGET partout-zig)
        set(PARTOUT_ZIG_BYPRODUCTS "${PP_BUILD_OUTPUT}/partout/lib/libpartout.a")
    endif()
    add_custom_target(${PARTOUT_COMPILE_TARGET} ALL
        COMMAND "${PARTOUT_ZIG_EXECUTABLE}" ${PARTOUT_ZIG_ARGS}
        BYPRODUCTS ${PARTOUT_ZIG_BYPRODUCTS}
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        USES_TERMINAL
        COMMAND_EXPAND_LISTS
        VERBATIM
    )
    if(PP_BUILD_USE_WIREGUARD)
        add_dependencies(${PARTOUT_COMPILE_TARGET} partout-wg-go)
    endif()
    if(PP_BUILD_WINRT)
        add_dependencies(${PARTOUT_COMPILE_TARGET} partout-winrt)
    endif()

    if(APPLE)
        set(PP_BUILD_APPLE_INSTALL_NAME "@rpath/libpartout.dylib" CACHE STRING
            "Install name for the Apple shared library")
        set_source_files_properties(${PARTOUT_ZIG_BYPRODUCTS} PROPERTIES GENERATED TRUE)
        add_library(partout SHARED ${PARTOUT_ZIG_BYPRODUCTS})
        set_target_properties(partout PROPERTIES
            LINKER_LANGUAGE C
            LIBRARY_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib"
            OUTPUT_NAME partout
            NO_SONAME TRUE
        )
        add_dependencies(partout partout-zig)
        target_link_options(partout PRIVATE
            "LINKER:-install_name,${PP_BUILD_APPLE_INSTALL_NAME}"
            "LINKER:-compatibility_version,1.0.0" "LINKER:-current_version,1.0.0"
            "LINKER:-dead_strip" "LINKER:-rpath,@loader_path"
            "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports"
            "LINKER:-force_load,${PP_BUILD_OUTPUT}/partout/lib/libpartout.a"
        )
        set_property(TARGET partout APPEND PROPERTY LINK_DEPENDS
            "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports" ${PARTOUT_ZIG_BYPRODUCTS})
        target_link_libraries(partout PRIVATE ${PARTOUT_APPLE_LIBRARIES}
            "-framework CoreFoundation" "-framework Security")
        if(PP_BUILD_USE_WIREGUARD)
            target_link_libraries(partout PRIVATE Partout::WireGuard)
        endif()
    endif()

    file(MAKE_DIRECTORY "${PP_BUILD_OUTPUT}/partout/include")
    if(WIN32)
        add_library(Partout::Partout SHARED IMPORTED GLOBAL)
        set_target_properties(Partout::Partout PROPERTIES
            IMPORTED_IMPLIB "${PARTOUT_LINK_LIBRARY}"
            IMPORTED_LOCATION "${PP_BUILD_OUTPUT}/partout/bin/partout.dll"
        )
    else()
        add_library(Partout::Partout SHARED IMPORTED GLOBAL)
        set_target_properties(Partout::Partout PROPERTIES
            IMPORTED_LOCATION "${PARTOUT_LINK_LIBRARY}"
            IMPORTED_SONAME "${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}"
        )
    endif()
    add_dependencies(Partout::Partout partout)
    set(PARTOUT_INTERFACE_LIBRARIES ${PARTOUT_RUNTIME_LIBRARIES})
    set_target_properties(Partout::Partout PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${PP_BUILD_OUTPUT}/partout/include"
        INTERFACE_LINK_LIBRARIES "${PARTOUT_INTERFACE_LIBRARIES}"
    )
endif()
