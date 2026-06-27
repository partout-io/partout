cmake_minimum_required(VERSION 3.28)
if(POLICY CMP0157)
    cmake_policy(SET CMP0157 NEW)
endif()
project(Partout LANGUAGES C CXX)
include(ExternalProject)
include(FetchContent)
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
include("cmake/prebuilt.cmake")

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
set(PP_BUILD_VENDOR_SOURCE "auto" CACHE STRING "Vendor source: auto or bundled")
set_property(CACHE PP_BUILD_VENDOR_SOURCE PROPERTY STRINGS auto bundled)
set(PP_BUILD_VENDOR_PREBUILT_URL "" CACHE STRING "Base URL for prebuilt vendor archives")

# Output per platform/arch
string(TOLOWER ${CMAKE_SYSTEM_NAME} PLATFORM_NAME)
set(PP_TARGET_PROCESSOR "${CMAKE_SYSTEM_PROCESSOR}")
if(WIN32)
    if(CMAKE_C_COMPILER_ARCHITECTURE_ID)
        set(PP_TARGET_PROCESSOR "${CMAKE_C_COMPILER_ARCHITECTURE_ID}")
    elseif(CMAKE_C_COMPILER_TARGET)
        set(PP_TARGET_PROCESSOR "${CMAKE_C_COMPILER_TARGET}")
    elseif(DEFINED ENV{VSCMD_ARG_TGT_ARCH})
        set(PP_TARGET_PROCESSOR "$ENV{VSCMD_ARG_TGT_ARCH}")
    endif()
endif()
string(TOLOWER "${PP_TARGET_PROCESSOR}" ARCH_NAME)
if(WIN32)
    if(ARCH_NAME MATCHES "^(x64|x86_64|amd64)(-|$)")
        set(ARCH_NAME "amd64")
    elseif(ARCH_NAME MATCHES "^(arm64|aarch64)(-|$)")
        set(ARCH_NAME "arm64")
    endif()
endif()
if(DEFINED PP_BUILD_OUTPUT)
    set(PP_BUILD_OUTPUT_UNIVERSAL "${PP_BUILD_OUTPUT}")
else()
    set(PP_BUILD_OUTPUT_UNIVERSAL "${CMAKE_CURRENT_SOURCE_DIR}/bin")
    set(PP_BUILD_OUTPUT "${PP_BUILD_OUTPUT_UNIVERSAL}/${PLATFORM_NAME}-${ARCH_NAME}")
endif()
# Generated install scripts treat backslashes as escapes, so keep composed paths CMake-style.
string(REPLACE "\\" "/" PP_BUILD_OUTPUT_UNIVERSAL "${PP_BUILD_OUTPUT_UNIVERSAL}")
string(REPLACE "\\" "/" PP_BUILD_OUTPUT "${PP_BUILD_OUTPUT}")

set(PP_USE_SYSTEM_VENDORS OFF)
set(PP_USE_PREBUILT_VENDORS OFF)
if(NOT PP_BUILD_VENDOR_SOURCE MATCHES "^(auto|bundled)$")
    message(FATAL_ERROR "PP_BUILD_VENDOR_SOURCE must be auto or bundled")
endif()
if(PP_BUILD_VENDOR_SOURCE STREQUAL "auto")
    if(ANDROID OR WIN32)
        set(PP_USE_PREBUILT_VENDORS ON)
        if(NOT PP_BUILD_VENDOR_PREBUILT_URL)
            message(FATAL_ERROR "PP_BUILD_VENDOR_PREBUILT_URL must be set when PP_BUILD_VENDOR_SOURCE=auto on Android or Windows")
        endif()
    else()
        set(PP_USE_SYSTEM_VENDORS ON)
    endif()
endif()
set(PP_BUNDLE_VENDOR_RUNTIME OFF)
if(PP_BUILD_VENDOR_SOURCE STREQUAL "bundled" OR PP_USE_PREBUILT_VENDORS)
    set(PP_BUNDLE_VENDOR_RUNTIME ON)
endif()
set(PKG_CONFIG_USE_CMAKE_PREFIX_PATH ON)
if(APPLE AND PP_USE_SYSTEM_VENDORS)
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
message(STATUS "Option PP_BUILD_VENDOR_SOURCE = ${PP_BUILD_VENDOR_SOURCE}")
message(STATUS "Option PP_BUILD_VENDOR_PREBUILT_URL = ${PP_BUILD_VENDOR_PREBUILT_URL}")
message(STATUS "Option PP_BUILD_OUTPUT = ${PP_BUILD_OUTPUT}")
message(STATUS "Option PP_BUILD_ARCH = ${ARCH_NAME}")

# All vendor-inherited args
if(WIN32)
    set(MAKE_CMD nmake)
else()
    set(MAKE_CMD make)
endif()

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
endif()
if(PP_BUILD_USE_MBEDTLS)
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
    enable_language(Swift)
    add_subdirectory(Sources)
    if(PP_BUILD_USE_OPENSSL)
        target_link_libraries(partout_c PRIVATE "$<BUILD_LOCAL_INTERFACE:OpenSSLInterface>")
        target_link_libraries(partout PUBLIC "$<BUILD_LOCAL_INTERFACE:OpenSSLInterface>")
    endif()
    if(PP_BUILD_USE_MBEDTLS)
        target_link_libraries(partout_c PRIVATE "$<BUILD_LOCAL_INTERFACE:MbedTLSInterface>")
        target_link_libraries(partout PUBLIC "$<BUILD_LOCAL_INTERFACE:MbedTLSInterface>")
    endif()
    if(PP_BUILD_USE_WIREGUARD)
        target_link_libraries(partout_c PRIVATE "$<BUILD_LOCAL_INTERFACE:WireGuardGoInterface>")
        target_link_libraries(partout PUBLIC "$<BUILD_LOCAL_INTERFACE:WireGuardGoInterface>")
    endif()
endif()

# Vendor-only installs keep each vendor's own install prefix layout.
if(NOT PP_BUILD_LIBRARY)
    function(partout_install_vendor_directory vendor source_dir)
        get_filename_component(vendor_source_dir "${source_dir}" ABSOLUTE)
        get_filename_component(vendor_install_dir "${CMAKE_INSTALL_PREFIX}/${vendor}" ABSOLUTE)
        file(TO_CMAKE_PATH "${vendor_source_dir}" vendor_source_dir)
        file(TO_CMAKE_PATH "${vendor_install_dir}" vendor_install_dir)
        if(vendor_source_dir STREQUAL vendor_install_dir)
            return()
        endif()

        install(DIRECTORY "${source_dir}/"
            DESTINATION "${vendor}"
            USE_SOURCE_PERMISSIONS
        )
    endfunction()

    if(PP_BUNDLE_VENDOR_RUNTIME AND PP_BUILD_USE_OPENSSL)
        partout_install_vendor_directory(openssl "${OPENSSL_DIR}")
    endif()
    if(PP_BUNDLE_VENDOR_RUNTIME AND PP_BUILD_USE_MBEDTLS)
        partout_install_vendor_directory(mbedtls "${MBEDTLS_DIR}")
    endif()
    if(PP_BUILD_USE_WIREGUARD)
        partout_install_vendor_directory(wg-go "${WGGO_DIR}")
    endif()
    if(WIN32)
        partout_install_vendor_directory(wintun "${WINTUN_DIR}")
    endif()
else()
    set(PARTOUT_RUNTIME_DEPENDENCY_SET PartoutRuntimeDependencies)
    set(PARTOUT_IMPORTED_RUNTIME_TARGETS "")
    set(PARTOUT_RUNTIME_DEPENDENCY_DIRS "")
    set(PARTOUT_IMPORTED_STATIC_TARGET_FILES "")
    function(partout_install_runtime_target target)
        if(NOT TARGET ${target})
            message(FATAL_ERROR "Missing runtime dependency target: ${target}")
        endif()
        list(APPEND PARTOUT_IMPORTED_RUNTIME_TARGETS ${target})
        get_target_property(runtime_location ${target} IMPORTED_LOCATION)
        if(runtime_location)
            get_filename_component(runtime_dir "${runtime_location}" DIRECTORY)
            list(APPEND PARTOUT_RUNTIME_DEPENDENCY_DIRS "${runtime_dir}")
        endif()
        set(PARTOUT_IMPORTED_RUNTIME_TARGETS "${PARTOUT_IMPORTED_RUNTIME_TARGETS}" PARENT_SCOPE)
        set(PARTOUT_RUNTIME_DEPENDENCY_DIRS "${PARTOUT_RUNTIME_DEPENDENCY_DIRS}" PARENT_SCOPE)
    endfunction()

    function(partout_install_static_target target)
        if(NOT TARGET ${target})
            message(FATAL_ERROR "Missing static dependency target: ${target}")
        endif()
        get_target_property(static_location ${target} IMPORTED_LOCATION)
        if(NOT static_location)
            message(FATAL_ERROR "Static dependency target has no IMPORTED_LOCATION: ${target}")
        endif()
        list(APPEND PARTOUT_IMPORTED_STATIC_TARGET_FILES "${static_location}")
        set(PARTOUT_IMPORTED_STATIC_TARGET_FILES "${PARTOUT_IMPORTED_STATIC_TARGET_FILES}" PARENT_SCOPE)
    endfunction()

    if(PP_BUNDLE_VENDOR_RUNTIME AND PP_BUILD_USE_OPENSSL)
        partout_install_runtime_target(OpenSSL::SSL)
        partout_install_runtime_target(OpenSSL::Crypto)
    endif()
    if(PP_BUNDLE_VENDOR_RUNTIME AND PP_BUILD_USE_MBEDTLS)
        partout_install_static_target(MbedTLS::TLS)
        partout_install_static_target(MbedTLS::X509)
        partout_install_static_target(MbedTLS::Crypto)
    endif()
    if(PP_BUILD_USE_WIREGUARD)
        partout_install_runtime_target(WireGuardGo::wg-go)
    endif()
    if(WIN32)
        partout_install_runtime_target(Wintun::Wintun)
    endif()
    if(PARTOUT_IMPORTED_RUNTIME_TARGETS)
        list(REMOVE_DUPLICATES PARTOUT_RUNTIME_DEPENDENCY_DIRS)
        install(IMPORTED_RUNTIME_ARTIFACTS ${PARTOUT_IMPORTED_RUNTIME_TARGETS}
            RUNTIME_DEPENDENCY_SET ${PARTOUT_RUNTIME_DEPENDENCY_SET}
            LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        )

        set(PARTOUT_RUNTIME_ROOT "${PP_BUILD_OUTPUT}")
        set(PARTOUT_RUNTIME_DEPENDENCY_ARGS
            POST_INCLUDE_REGEXES "^${PARTOUT_RUNTIME_ROOT}/"
            POST_EXCLUDE_REGEXES ".*"
        )
        if(WIN32)
            list(APPEND PARTOUT_RUNTIME_DEPENDENCY_ARGS
                PRE_EXCLUDE_REGEXES
                    "api-ms-"
                    "ext-ms-"
            )
        elseif(ANDROID)
            list(APPEND PARTOUT_RUNTIME_DEPENDENCY_ARGS
                PRE_EXCLUDE_REGEXES
                    "^libandroid\\.so$"
                    "^libc\\.so$"
                    "^libdl\\.so$"
                    "^liblog\\.so$"
                    "^libm\\.so$"
            )
        endif()
        if(ANDROID AND CMAKE_OBJDUMP)
            string(REPLACE "\\" "/" PARTOUT_CMAKE_OBJDUMP "${CMAKE_OBJDUMP}")
            install(CODE
                "set(CMAKE_GET_RUNTIME_DEPENDENCIES_PLATFORM \"linux+elf\")
set(CMAKE_GET_RUNTIME_DEPENDENCIES_TOOL \"objdump\")
set(CMAKE_GET_RUNTIME_DEPENDENCIES_COMMAND \"${PARTOUT_CMAKE_OBJDUMP}\")"
            )
        endif()
        install(RUNTIME_DEPENDENCY_SET ${PARTOUT_RUNTIME_DEPENDENCY_SET}
            ${PARTOUT_RUNTIME_DEPENDENCY_ARGS}
            DIRECTORIES ${PARTOUT_RUNTIME_DEPENDENCY_DIRS}
            LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
            RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
        )
    endif()
    if(PARTOUT_IMPORTED_STATIC_TARGET_FILES)
        install(FILES ${PARTOUT_IMPORTED_STATIC_TARGET_FILES}
            DESTINATION ${CMAKE_INSTALL_LIBDIR}
        )
    endif()
endif()

if(PP_BUILD_LIBRARY)
    set(PP_INSTALL_CMAKEDIR "${CMAKE_INSTALL_LIBDIR}/cmake/Partout")
    configure_package_config_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/cmake/PartoutConfig.cmake.in"
        "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
        INSTALL_DESTINATION "${PP_INSTALL_CMAKEDIR}"
    )
    install(EXPORT PartoutTargets
        FILE PartoutTargets.cmake
        NAMESPACE Partout::
        DESTINATION "${PP_INSTALL_CMAKEDIR}"
    )
    install(FILES
        "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
        DESTINATION "${PP_INSTALL_CMAKEDIR}"
    )
endif()
