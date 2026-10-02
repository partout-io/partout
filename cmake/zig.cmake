set(PARTOUT_ZIG_ARGS
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    "-Dstrip=$<IF:$<CONFIG:Debug,RelWithDebInfo>,false,true>"
)

if(PP_BUILD_USE_OPENSSL)
    if(PP_BUILD_OPENSSL_INCLUDE AND PP_BUILD_OPENSSL_LIB)
        set(PARTOUT_OPENSSL_INCLUDE_DIR "${PP_BUILD_OPENSSL_INCLUDE}")
        set(PARTOUT_OPENSSL_LIBRARY_DIR "${PP_BUILD_OPENSSL_LIB}")
    else()
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
    if(PP_BUILD_MBEDTLS_INCLUDE AND PP_BUILD_MBEDTLS_LIB)
        set(PARTOUT_MBEDTLS_INCLUDE_DIR "${PP_BUILD_MBEDTLS_INCLUDE}")
        set(PARTOUT_MBEDTLS_LIBRARY_DIR "${PP_BUILD_MBEDTLS_LIB}")
    else()
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
    list(APPEND PARTOUT_ZIG_ARGS -Dwireguard=true "-Dwg-go-lib=$<TARGET_LINKER_FILE:partout-wg-go>")
endif()
if(PP_BUILD_WINRT)
    list(APPEND PARTOUT_ZIG_ARGS "-Dwinrt-lib=$<TARGET_FILE:partout-winrt>")
endif()
if(PARTOUT_ZIG_TARGET)
    list(APPEND PARTOUT_ZIG_ARGS "-Dtarget=${PARTOUT_ZIG_TARGET}")
endif()
if(PARTOUT_ZIG_LIBC)
    list(APPEND PARTOUT_ZIG_ARGS --libc "${PARTOUT_ZIG_LIBC}")
endif()
if(PARTOUT_APPLE_SDK)
    list(APPEND PARTOUT_ZIG_ARGS "-Dapple-sdk-path=${PARTOUT_APPLE_SDK}")
endif()
find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)

# Both entry points share compiler settings and consume CMake-built bridges.
set(zig_env "${CMAKE_COMMAND}" -E env)
if(WIN32)
    list(APPEND zig_env --modify "PATH=path_list_prepend:${PP_BUILD_OUTPUT}/partout/bin")
endif()
add_custom_target(partout-test
    COMMAND ${zig_env} "${PARTOUT_ZIG_EXECUTABLE}" build test ${PARTOUT_ZIG_ARGS}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL COMMAND_EXPAND_LISTS VERBATIM)

if(PP_BUILD_LIBRARY)
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

    set(PP_BUILD_INSTALL_NAME "" CACHE STRING "Apple dylib install name")
    if(PP_BUILD_INSTALL_NAME)
        list(APPEND PARTOUT_ZIG_ARGS "-Dinstall-name=${PP_BUILD_INSTALL_NAME}")
    endif()

    add_custom_target(partout ALL
        COMMAND "${PARTOUT_ZIG_EXECUTABLE}" build install
            --prefix "${PP_BUILD_OUTPUT}/partout" -Dshared=true ${PARTOUT_ZIG_ARGS}
        BYPRODUCTS ${PARTOUT_ZIG_BYPRODUCTS}
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        USES_TERMINAL
        COMMAND_EXPAND_LISTS
        VERBATIM
    )
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

foreach(bridge partout-wg-go partout-winrt)
    if(TARGET ${bridge})
        add_dependencies(partout-test ${bridge})
        if(PP_BUILD_LIBRARY)
            add_dependencies(partout ${bridge})
        endif()
    endif()
endforeach()
