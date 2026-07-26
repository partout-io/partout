if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    cmake_minimum_required(VERSION 3.28)
    project(PartoutZig LANGUAGES C)
endif()
include(ExternalProject)
include(GNUInstallDirs)

# Package root is up one level, output dir from option
set(ROOT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(ZIG_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
if(NOT DEFINED PP_BUILD_OUTPUT)
    set(PP_BUILD_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/output")
endif()
if(NOT DEFINED ARCH_NAME)
    string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" ARCH_NAME)
endif()
set(OUTPUT_DIR "${PP_BUILD_OUTPUT}/partout")

find_program(PARTOUT_ZIG_EXECUTABLE NAMES zig REQUIRED)
include("${ZIG_DIR}/src/files.cmake")

list(TRANSFORM PARTOUT_ZIG_SOURCES PREPEND "${ZIG_DIR}/")
list(TRANSFORM PARTOUT_C_SOURCES PREPEND "${ZIG_DIR}/")

function(partout_first_include_directory output_var)
    foreach(candidate IN LISTS ARGN)
        if(candidate AND NOT candidate MATCHES "-NOTFOUND$" AND IS_DIRECTORY "${candidate}")
            set(${output_var} "${candidate}" PARENT_SCOPE)
            return()
        endif()
    endforeach()
    set(${output_var} "" PARENT_SCOPE)
endfunction()

function(partout_first_library_directory output_var)
    foreach(candidate IN LISTS ARGN)
        if(NOT candidate OR candidate MATCHES "-NOTFOUND$")
            continue()
        endif()
        if(IS_DIRECTORY "${candidate}")
            set(${output_var} "${candidate}" PARENT_SCOPE)
            return()
        endif()
        if(EXISTS "${candidate}")
            get_filename_component(candidate_dir "${candidate}" DIRECTORY)
            set(${output_var} "${candidate_dir}" PARENT_SCOPE)
            return()
        endif()
    endforeach()
    set(${output_var} "" PARENT_SCOPE)
endfunction()

function(partout_target_vendor_paths output_include output_library target)
    if(NOT target OR NOT TARGET ${target})
        set(${output_include} "" PARENT_SCOPE)
        set(${output_library} "" PARENT_SCOPE)
        return()
    endif()

    get_target_property(include_dirs ${target} INTERFACE_INCLUDE_DIRECTORIES)
    get_target_property(system_include_dirs ${target} INTERFACE_SYSTEM_INCLUDE_DIRECTORIES)
    partout_first_include_directory(include_dir ${include_dirs} ${system_include_dirs})

    get_target_property(link_dirs ${target} INTERFACE_LINK_DIRECTORIES)
    get_target_property(imported_location ${target} IMPORTED_LOCATION)
    get_target_property(imported_configurations ${target} IMPORTED_CONFIGURATIONS)
    set(imported_locations "${imported_location}")
    foreach(configuration IN LISTS imported_configurations)
        string(TOUPPER "${configuration}" configuration_upper)
        get_target_property(config_location ${target} "IMPORTED_LOCATION_${configuration_upper}")
        list(APPEND imported_locations "${config_location}")
    endforeach()
    partout_first_library_directory(library_dir ${link_dirs} ${imported_locations})

    set(${output_include} "${include_dir}" PARENT_SCOPE)
    set(${output_library} "${library_dir}" PARENT_SCOPE)
endfunction()

set(PARTOUT_ZIG_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/external")
set(PARTOUT_ZIG_INSTALL_DIR "${PARTOUT_ZIG_BUILD_DIR}/install")
set(PARTOUT_ZIG_ARGS
    build
    install
    --prefix "${PARTOUT_ZIG_INSTALL_DIR}"
    --cache-dir "${PARTOUT_ZIG_BUILD_DIR}/cache"
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    -Dembed-c=true
)
if(PP_BUILD_STATIC)
    list(APPEND PARTOUT_ZIG_ARGS -Dshared=false)
else()
    list(APPEND PARTOUT_ZIG_ARGS -Dshared=true)
endif()
if(PP_BUILD_USE_OPENVPN)
    list(APPEND PARTOUT_ZIG_ARGS -Dopenvpn=true)
endif()
if(PP_BUILD_USE_WIREGUARD)
    list(APPEND PARTOUT_ZIG_ARGS -Dwireguard=true)
endif()

set(PARTOUT_ZIG_ARCH "${ARCH_NAME}")
if(PARTOUT_ZIG_ARCH MATCHES "^(arm64|aarch64)$")
    set(PARTOUT_ZIG_ARCH aarch64)
elseif(PARTOUT_ZIG_ARCH MATCHES "^(x64|amd64|x86_64)$")
    set(PARTOUT_ZIG_ARCH x86_64)
endif()
if(ANDROID)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-android")
elseif(APPLE)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-macos")
elseif(WIN32)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-windows-msvc")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-gnu")
endif()
if(PARTOUT_ZIG_TARGET)
    list(APPEND PARTOUT_ZIG_ARGS "-Dtarget=${PARTOUT_ZIG_TARGET}")
endif()

if(APPLE)
    set(PARTOUT_APPLE_SDK_PATH "")
    if(IS_DIRECTORY "${CMAKE_OSX_SYSROOT}")
        set(PARTOUT_APPLE_SDK_PATH "${CMAKE_OSX_SYSROOT}")
    else()
        find_program(PARTOUT_XCRUN_EXECUTABLE NAMES xcrun)
        if(PARTOUT_XCRUN_EXECUTABLE)
            execute_process(
                COMMAND "${PARTOUT_XCRUN_EXECUTABLE}" --sdk macosx --show-sdk-path
                RESULT_VARIABLE PARTOUT_XCRUN_RESULT
                OUTPUT_VARIABLE PARTOUT_APPLE_SDK_PATH
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_QUIET
            )
            if(NOT PARTOUT_XCRUN_RESULT EQUAL 0)
                set(PARTOUT_APPLE_SDK_PATH "")
            endif()
        endif()
    endif()
    if(PARTOUT_APPLE_SDK_PATH)
        list(APPEND PARTOUT_ZIG_ARGS "-Dapple-sdk-path=${PARTOUT_APPLE_SDK_PATH}")
    endif()
endif()

set(PARTOUT_ZIG_DEPENDENCIES "")
if(PP_BUILD_USE_OPENSSL)
    if(PP_OPENSSL_IS_SYSTEM)
        partout_target_vendor_paths(
            PARTOUT_OPENSSL_TARGET_INCLUDE
            PARTOUT_OPENSSL_TARGET_LIBRARY
            OpenSSL::SSL
        )
        partout_first_include_directory(
            PARTOUT_OPENSSL_INCLUDE
            ${OPENSSL_INCLUDE_DIR}
            ${OPENSSL_INCLUDE_DIRS}
            ${OPENSSL_PKG_INCLUDE_DIRS}
            ${PARTOUT_OPENSSL_TARGET_INCLUDE}
        )
        partout_first_library_directory(
            PARTOUT_OPENSSL_LIBRARY
            ${OPENSSL_SSL_LIBRARY}
            ${OPENSSL_LIBRARIES}
            ${OPENSSL_PKG_LIBRARY_DIRS}
            ${PARTOUT_OPENSSL_TARGET_LIBRARY}
        )
    else()
        set(PARTOUT_OPENSSL_INCLUDE "${OPENSSL_DIR}/include")
        set(PARTOUT_OPENSSL_LIBRARY "${OPENSSL_DIR}/${OPENSSL_LIBDIR}")
    endif()
    if(NOT PARTOUT_OPENSSL_INCLUDE OR NOT PARTOUT_OPENSSL_LIBRARY)
        message(FATAL_ERROR "Unable to resolve OpenSSL include/library directories for Zig")
    endif()
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dopenssl-include=${PARTOUT_OPENSSL_INCLUDE}"
        "-Dopenssl-lib=${PARTOUT_OPENSSL_LIBRARY}"
    )
    if(TARGET OpenSSLInterface)
        list(APPEND PARTOUT_ZIG_DEPENDENCIES OpenSSLInterface)
    endif()
endif()

if(PP_BUILD_USE_MBEDTLS)
    if(PP_MBEDTLS_IS_SYSTEM)
        if(TARGET MbedTLS::mbedtls)
            set(PARTOUT_MBEDTLS_TARGET MbedTLS::mbedtls)
        elseif(TARGET PkgConfig::MBEDTLS_PKG)
            set(PARTOUT_MBEDTLS_TARGET PkgConfig::MBEDTLS_PKG)
        endif()
        partout_target_vendor_paths(
            PARTOUT_MBEDTLS_TARGET_INCLUDE
            PARTOUT_MBEDTLS_TARGET_LIBRARY
            "${PARTOUT_MBEDTLS_TARGET}"
        )
        partout_first_include_directory(
            PARTOUT_MBEDTLS_INCLUDE
            ${MBEDTLS_INCLUDE_DIR}
            ${MBEDTLS_INCLUDE_DIRS}
            ${MBEDTLS_PKG_INCLUDE_DIRS}
            ${PARTOUT_MBEDTLS_TARGET_INCLUDE}
        )
        partout_first_library_directory(
            PARTOUT_MBEDTLS_LIBRARY
            ${MBEDTLS_LIBRARY_DIR}
            ${MBEDTLS_LIBRARY_DIRS}
            ${MBEDTLS_PKG_LIBRARY_DIRS}
            ${PARTOUT_MBEDTLS_TARGET_LIBRARY}
        )
    else()
        set(PARTOUT_MBEDTLS_INCLUDE "${MBEDTLS_DIR}/include")
        set(PARTOUT_MBEDTLS_LIBRARY "${MBEDTLS_DIR}/lib")
    endif()
    if(NOT PARTOUT_MBEDTLS_INCLUDE OR NOT PARTOUT_MBEDTLS_LIBRARY)
        message(FATAL_ERROR "Unable to resolve MbedTLS include/library directories for Zig")
    endif()
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dmbedtls-include=${PARTOUT_MBEDTLS_INCLUDE}"
        "-Dmbedtls-lib=${PARTOUT_MBEDTLS_LIBRARY}"
    )
    if(TARGET MbedTLSInterface)
        list(APPEND PARTOUT_ZIG_DEPENDENCIES MbedTLSInterface)
    endif()
endif()

if(PP_BUILD_USE_WIREGUARD)
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dwg-go-include=${WGGO_DIR}/include"
        "-Dwg-go-lib=${WGGO_DIR}/lib"
    )
    if(TARGET WireGuardGoInterface)
        list(APPEND PARTOUT_ZIG_DEPENDENCIES WireGuardGoInterface)
    endif()
endif()
if(WIN32)
    list(APPEND PARTOUT_ZIG_ARGS "-Dwintun-include=${WINTUN_DIR}")
endif()

if(PP_BUILD_STATIC)
    set(PARTOUT_ZIG_LIBRARY
        "${PARTOUT_ZIG_INSTALL_DIR}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}partout${CMAKE_STATIC_LIBRARY_SUFFIX}"
    )
else()
    if(WIN32)
        set(PARTOUT_ZIG_LIBRARY
            "${PARTOUT_ZIG_INSTALL_DIR}/bin/${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}"
        )
        set(PARTOUT_ZIG_IMPORT_LIBRARY
            "${PARTOUT_ZIG_INSTALL_DIR}/lib/${CMAKE_IMPORT_LIBRARY_PREFIX}partout${CMAKE_IMPORT_LIBRARY_SUFFIX}"
        )
    else()
        set(PARTOUT_ZIG_LIBRARY
            "${PARTOUT_ZIG_INSTALL_DIR}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}"
        )
    endif()
endif()

set(PARTOUT_ZIG_BYPRODUCTS "${PARTOUT_ZIG_LIBRARY}")
if(PARTOUT_ZIG_IMPORT_LIBRARY)
    list(APPEND PARTOUT_ZIG_BYPRODUCTS "${PARTOUT_ZIG_IMPORT_LIBRARY}")
endif()
ExternalProject_Add(PartoutZigProject
    SOURCE_DIR "${ZIG_DIR}"
    BINARY_DIR "${PARTOUT_ZIG_BUILD_DIR}"
    CONFIGURE_COMMAND ""
    BUILD_COMMAND
        "${CMAKE_COMMAND}" -E chdir "${ZIG_DIR}"
        "${PARTOUT_ZIG_EXECUTABLE}" ${PARTOUT_ZIG_ARGS}
    INSTALL_COMMAND ""
    BUILD_ALWAYS TRUE
    BUILD_BYPRODUCTS ${PARTOUT_ZIG_BYPRODUCTS}
    DEPENDS ${PARTOUT_ZIG_DEPENDENCIES}
    USES_TERMINAL_BUILD TRUE
)
target_sources(PartoutZigProject PRIVATE
    ${PARTOUT_ZIG_SOURCES}
    ${PARTOUT_C_SOURCES}
)

# Keep a regular CMake library target so the parent can link, install, and
# export it normally. Its placeholder binary is replaced only when Zig emits
# a different artifact.
add_library(partout_c STATIC EXCLUDE_FROM_ALL src/cmake_stub.c)
if(PP_BUILD_STATIC)
    add_library(partout STATIC src/cmake_stub.c)
else()
    add_library(partout SHARED src/cmake_stub.c)
endif()
add_library(Partout::partout ALIAS partout)
add_dependencies(partout PartoutZigProject)
set_property(TARGET partout APPEND PROPERTY LINK_DEPENDS "${PARTOUT_ZIG_LIBRARY}")

add_custom_command(TARGET partout POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${PARTOUT_ZIG_LIBRARY}"
        "$<TARGET_FILE:partout>"
    COMMENT "Installing Zig artifact as $<TARGET_FILE_NAME:partout>"
    VERBATIM
)
if(PARTOUT_ZIG_IMPORT_LIBRARY)
    add_custom_command(TARGET partout POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${PARTOUT_ZIG_IMPORT_LIBRARY}"
            "$<TARGET_LINKER_FILE:partout>"
        VERBATIM
    )
endif()

target_sources(partout
    PUBLIC
        FILE_SET api_headers
        TYPE HEADERS
        BASE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/src"
        FILES "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.h"
)
target_include_directories(partout PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)
set_target_properties(partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
    ARCHIVE_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${OUTPUT_DIR}"
)

install(TARGETS partout
    EXPORT PartoutTargets
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
    FILE_SET api_headers DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
install(FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/src/module.modulemap"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
