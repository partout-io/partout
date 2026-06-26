cmake_minimum_required(VERSION 3.28)
if(POLICY CMP0157)
    cmake_policy(SET CMP0157 NEW)
endif()
project(Partout LANGUAGES Swift C CXX)
include(ExternalProject)
include(FetchContent)
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
include("cmake/AddDistributionTarget.function.cmake")

# Be quite strict
set(CMAKE_C_FLAGS "
    -W -Wall -Wextra -pedantic -Werror \
    -Wno-nullability-extension \
    -Wno-language-extension-token"
)
set(CMAKE_CXX_FLAGS ${CMAKE_C_FLAGS})

# Command line options
option(PP_BUILD_LIBRARY "Include main library" 0)
option(PP_BUILD_STATIC "Build as static library" 0)
option(PP_BUILD_USE_OPENSSL "Use OpenSSL" 0)
option(PP_BUILD_USE_MBEDTLS "Use MbedTLS" 0)
option(PP_BUILD_USE_OPENVPN "Use OpenVPN" 0)
option(PP_BUILD_USE_WIREGUARD "Use WireGuard" 0)
option(PP_BUILD_USE_SYSTEM_VENDORS "Prefer system vendor packages on macOS and Linux" 1)

# Output per platform/arch
string(TOLOWER ${CMAKE_SYSTEM_NAME} PLATFORM_NAME)
string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} ARCH_NAME)
if(DEFINED PP_BUILD_OUTPUT)
    set(PP_BUILD_OUTPUT_UNIVERSAL "${PP_BUILD_OUTPUT}")
else()
    set(PP_BUILD_OUTPUT_UNIVERSAL "${CMAKE_CURRENT_SOURCE_DIR}/bin")
    set(PP_BUILD_OUTPUT "${PP_BUILD_OUTPUT_UNIVERSAL}/${PLATFORM_NAME}-${ARCH_NAME}")
endif()

set(PARTOUT_SYSTEM_VENDOR_SEARCH OFF)
if(PP_BUILD_USE_SYSTEM_VENDORS AND (APPLE OR LINUX))
    set(PARTOUT_SYSTEM_VENDOR_SEARCH ON)
endif()
set(PKG_CONFIG_USE_CMAKE_PREFIX_PATH ON)
if(APPLE AND PARTOUT_SYSTEM_VENDOR_SEARCH)
    find_program(HOMEBREW_EXECUTABLE brew)
endif()

function(partout_use_homebrew_formula formula)
    if(NOT HOMEBREW_EXECUTABLE)
        return()
    endif()
    execute_process(
        COMMAND "${HOMEBREW_EXECUTABLE}" --prefix "${formula}"
        RESULT_VARIABLE result
        OUTPUT_VARIABLE prefix
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(result EQUAL 0 AND IS_DIRECTORY "${prefix}")
        list(PREPEND CMAKE_PREFIX_PATH "${prefix}")
        set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}" PARENT_SCOPE)
    endif()
endfunction()

# Options
message(STATUS "Option CMAKE_BUILD_TYPE = ${CMAKE_BUILD_TYPE}")
message(STATUS "Option PP_BUILD_LIBRARY = ${PP_BUILD_LIBRARY}")
message(STATUS "Option PP_BUILD_STATIC = ${PP_BUILD_STATIC}")
message(STATUS "Option PP_BUILD_USE_OPENSSL = ${PP_BUILD_USE_OPENSSL}")
message(STATUS "Option PP_BUILD_USE_MBEDTLS = ${PP_BUILD_USE_MBEDTLS}")
message(STATUS "Option PP_BUILD_USE_OPENVPN = ${PP_BUILD_USE_OPENVPN}")
message(STATUS "Option PP_BUILD_USE_WIREGUARD = ${PP_BUILD_USE_WIREGUARD}")
message(STATUS "Option PP_BUILD_USE_SYSTEM_VENDORS = ${PP_BUILD_USE_SYSTEM_VENDORS}")
message(STATUS "Option PP_BUILD_OUTPUT = ${PP_BUILD_OUTPUT}")
message(STATUS "System vendor search = ${PARTOUT_SYSTEM_VENDOR_SEARCH}")

# All vendor-inherited args
if(WIN32)
    set(MAKE_CMD nmake)
else()
    set(MAKE_CMD make)
endif()
set(LIBEXT ${CMAKE_SHARED_LIBRARY_SUFFIX})
set(LIBEXT_STATIC ${CMAKE_STATIC_LIBRARY_SUFFIX})
set(LIBEXT_IMP ${CMAKE_IMPORT_LIBRARY_SUFFIX})
set(LIBPFX_STATIC ${CMAKE_STATIC_LIBRARY_PREFIX})

# Define VENDOR_ENV to prepend NDK toolchain on Android
if(ANDROID)
    if(NOT ANDROID_TOOLCHAIN_ROOT)
        if(NOT CMAKE_ANDROID_NDK)
            message(FATAL_ERROR "CMAKE_ANDROID_NDK must be defined")
        endif()
        file(GLOB _android_toolchain_roots "${CMAKE_ANDROID_NDK}/toolchains/llvm/prebuilt/*")
        list(GET _android_toolchain_roots 0 ANDROID_TOOLCHAIN_ROOT)
        unset(_android_toolchain_roots)
    endif()
    if(CMAKE_HOST_WIN32)
        set(VENDOR_PATH "${ANDROID_TOOLCHAIN_ROOT}/bin;$ENV{PATH}")
        string(REPLACE ";" "\\;" VENDOR_PATH "${VENDOR_PATH}")
    else()
        set(VENDOR_PATH "${ANDROID_TOOLCHAIN_ROOT}/bin:$ENV{PATH}")
    endif()
    set(VENDOR_ENV ${CMAKE_COMMAND} -E env PATH=${VENDOR_PATH})
endif()

if(PP_BUILD_USE_OPENSSL)
    include("vendors/openssl.cmake")
elseif(PP_BUILD_USE_MBEDTLS)
    include("vendors/mbedtls.cmake")
endif()
if(PP_BUILD_USE_WIREGUARD)
    include("vendors/wg-go.cmake")
endif()

# Fetch wintun.dll on Windows
if(WIN32)
    set(WINTUN_VERSION "0.14.1")
    include("vendors/wintun.cmake")
endif()

# Build Partout library (opt-in), after vendored dependencies
if(PP_BUILD_LIBRARY)
    add_subdirectory(Sources)
    if(PP_BUILD_USE_OPENSSL)
        target_link_libraries(partout_c PRIVATE "$<BUILD_LOCAL_INTERFACE:OpenSSLInterface>")
        target_link_libraries(partout PUBLIC "$<BUILD_LOCAL_INTERFACE:OpenSSLInterface>")
    elseif(PP_BUILD_USE_MBEDTLS)
        target_link_libraries(partout_c PRIVATE "$<BUILD_LOCAL_INTERFACE:MbedTLSInterface>")
        target_link_libraries(partout PUBLIC "$<BUILD_LOCAL_INTERFACE:MbedTLSInterface>")
    endif()
    if(PP_BUILD_USE_WIREGUARD)
        target_link_libraries(partout_c PRIVATE "$<BUILD_LOCAL_INTERFACE:WireGuardGoInterface>")
        target_link_libraries(partout PUBLIC "$<BUILD_LOCAL_INTERFACE:WireGuardGoInterface>")
    endif()

    # Install
    set(PARTOUT_INSTALL_CMAKEDIR "${CMAKE_INSTALL_LIBDIR}/cmake/Partout")
    if(PP_BUILD_USE_OPENSSL AND NOT PARTOUT_OPENSSL_IS_SYSTEM)
        list(APPEND PARTOUT_VENDOR_BYPRODUCTS
            "${OPENSSL_DIR}/${LIBSSL}"
            "${OPENSSL_DIR}/${LIBCRYPTO}"
        )
        if(WIN32)
            list(APPEND PARTOUT_VENDOR_BYPRODUCTS
                "${OPENSSL_DIR}/${LIBSSL_IMP}"
                "${OPENSSL_DIR}/${LIBCRYPTO_IMP}"
            )
        endif()
    endif()
    if(PP_BUILD_USE_MBEDTLS AND NOT PARTOUT_MBEDTLS_IS_SYSTEM)
        list(APPEND PARTOUT_VENDOR_BYPRODUCTS
            "${MBEDTLS_DIR}/${LIBTLS}"
            "${MBEDTLS_DIR}/${LIBX509}"
            "${MBEDTLS_DIR}/${LIBCRYPTO}"
        )
    endif()
    if(PP_BUILD_USE_WIREGUARD)
        list(APPEND PARTOUT_VENDOR_BYPRODUCTS ${WGGO_BYPRODUCTS})
    endif()
    if(WIN32)
        list(APPEND PARTOUT_VENDOR_BYPRODUCTS "${WINTUN_DIR}/wintun.dll")
    endif()
    foreach(vendor_byproduct ${PARTOUT_VENDOR_BYPRODUCTS})
        file(RELATIVE_PATH vendor_byproduct_rel "${PP_BUILD_OUTPUT}" "${vendor_byproduct}")
        get_filename_component(vendor_byproduct_dir "${vendor_byproduct_rel}" DIRECTORY)
        install(FILES "${vendor_byproduct}" DESTINATION "${vendor_byproduct_dir}")
    endforeach()
    unset(PARTOUT_VENDOR_BYPRODUCTS)
    configure_package_config_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/cmake/PartoutConfig.cmake.in"
        "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
        INSTALL_DESTINATION "${PARTOUT_INSTALL_CMAKEDIR}"
    )
    install(EXPORT PartoutTargets
        FILE PartoutTargets.cmake
        NAMESPACE Partout::
        DESTINATION "${PARTOUT_INSTALL_CMAKEDIR}"
    )
    install(FILES
        "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
        DESTINATION "${PARTOUT_INSTALL_CMAKEDIR}"
    )
endif()
