set(PP_OPENSSL_IS_SYSTEM OFF)
if(PP_USE_SYSTEM_VENDORS)
    partout_use_homebrew_formula(openssl@3.5)
    find_package(OpenSSL 3 QUIET COMPONENTS SSL Crypto)
    if(OpenSSL_FOUND AND TARGET OpenSSL::SSL AND TARGET OpenSSL::Crypto)
        set(PP_OPENSSL_IS_SYSTEM ON)
        add_library(OpenSSLInterface INTERFACE)
        target_link_libraries(OpenSSLInterface INTERFACE OpenSSL::SSL OpenSSL::Crypto)
        message(STATUS "Using system OpenSSL")
        return()
    endif()

    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(OPENSSL_PKG QUIET IMPORTED_TARGET "openssl>=3")
        if(OPENSSL_PKG_FOUND AND TARGET PkgConfig::OPENSSL_PKG)
            set(PP_OPENSSL_IS_SYSTEM ON)
            add_library(OpenSSLInterface INTERFACE)
            target_link_libraries(OpenSSLInterface INTERFACE PkgConfig::OPENSSL_PKG)
            message(STATUS "Using system OpenSSL")
            return()
        endif()
    endif()

    message(FATAL_ERROR "System OpenSSL 3 not found")
endif()

set(OPENSSL_DIR ${PP_BUILD_OUTPUT}/openssl)
set(OPENSSL_LIBDIR "lib")
set(OPENSSL_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/openssl)
set(OPENSSL_BUILD_SOURCE_DIR ${CMAKE_CURRENT_BINARY_DIR}/vendors/openssl-src)

# Output
set(OPENSSL_SSL_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libssl${CMAKE_SHARED_LIBRARY_SUFFIX}")
set(OPENSSL_CRYPTO_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libcrypto${CMAKE_SHARED_LIBRARY_SUFFIX}")
if(NOT PP_USE_PREBUILT_VENDORS)
    if(WIN32)
        if(ARCH_NAME MATCHES "^(arm64|aarch64)$")
            set(OPENSSL_ARCH arm64)
        else()
            set(OPENSSL_ARCH x64)
        endif()
        set(OPENSSL_SSL_RUNTIME_LIBRARY "bin/libssl-3-${OPENSSL_ARCH}${CMAKE_SHARED_LIBRARY_SUFFIX}")
        set(OPENSSL_CRYPTO_RUNTIME_LIBRARY "bin/libcrypto-3-${OPENSSL_ARCH}${CMAKE_SHARED_LIBRARY_SUFFIX}")
    elseif(APPLE)
        set(OPENSSL_SSL_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libssl.3${CMAKE_SHARED_LIBRARY_SUFFIX}")
        set(OPENSSL_CRYPTO_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libcrypto.3${CMAKE_SHARED_LIBRARY_SUFFIX}")
    elseif(ANDROID)
        set(OPENSSL_SSL_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libssl${CMAKE_SHARED_LIBRARY_SUFFIX}")
        set(OPENSSL_CRYPTO_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libcrypto${CMAKE_SHARED_LIBRARY_SUFFIX}")
    else()
        set(OPENSSL_SSL_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libssl${CMAKE_SHARED_LIBRARY_SUFFIX}.3")
        set(OPENSSL_CRYPTO_RUNTIME_LIBRARY "${OPENSSL_LIBDIR}/libcrypto${CMAKE_SHARED_LIBRARY_SUFFIX}.3")
    endif()
endif()
set(OPENSSL_BYPRODUCTS
    <INSTALL_DIR>/${OPENSSL_SSL_RUNTIME_LIBRARY}
    <INSTALL_DIR>/${OPENSSL_CRYPTO_RUNTIME_LIBRARY}
)
if(WIN32)
    set(OPENSSL_SSL_IMPORT_LIBRARY "${OPENSSL_LIBDIR}/libssl${CMAKE_IMPORT_LIBRARY_SUFFIX}")
    set(OPENSSL_CRYPTO_IMPORT_LIBRARY "${OPENSSL_LIBDIR}/libcrypto${CMAKE_IMPORT_LIBRARY_SUFFIX}")
    list(APPEND OPENSSL_BYPRODUCTS
        <INSTALL_DIR>/${OPENSSL_SSL_IMPORT_LIBRARY}
        <INSTALL_DIR>/${OPENSSL_CRYPTO_IMPORT_LIBRARY}
    )
endif()

function(partout_import_openssl_targets ssl_runtime crypto_runtime ssl_import crypto_import)
    add_library(OpenSSL::SSL SHARED IMPORTED GLOBAL)
    add_library(OpenSSL::Crypto SHARED IMPORTED GLOBAL)
    set_target_properties(OpenSSL::SSL PROPERTIES
        IMPORTED_LOCATION "${ssl_runtime}"
    )
    set_target_properties(OpenSSL::Crypto PROPERTIES
        IMPORTED_LOCATION "${crypto_runtime}"
    )
    if(ssl_import AND crypto_import)
        set_target_properties(OpenSSL::SSL PROPERTIES
            IMPORTED_IMPLIB "${ssl_import}"
        )
        set_target_properties(OpenSSL::Crypto PROPERTIES
            IMPORTED_IMPLIB "${crypto_import}"
        )
    endif()
endfunction()

function(partout_find_openssl_runtime output_var library_dir library_name)
    file(GLOB runtime_candidates "${library_dir}/${library_name}*${CMAKE_SHARED_LIBRARY_SUFFIX}*")
    set(runtime_library "")
    foreach(candidate IN LISTS runtime_candidates)
        if(NOT IS_SYMLINK "${candidate}")
            set(runtime_library "${candidate}")
            break()
        endif()
    endforeach()
    if(NOT runtime_library AND runtime_candidates)
        list(GET runtime_candidates 0 runtime_library)
    endif()
    if(NOT runtime_library)
        message(FATAL_ERROR "Unable to locate prebuilt OpenSSL runtime library '${library_name}' in ${library_dir}")
    endif()
    set(${output_var} "${runtime_library}" PARENT_SCOPE)
endfunction()

if(PP_USE_PREBUILT_VENDORS)
    partout_fetch_prebuilt_vendor(openssl OPENSSL_DIR)
    if(WIN32)
        file(GLOB OPENSSL_SSL_RUNTIME_CANDIDATES "${OPENSSL_DIR}/bin/libssl-3*.dll")
        file(GLOB OPENSSL_CRYPTO_RUNTIME_CANDIDATES "${OPENSSL_DIR}/bin/libcrypto-3*.dll")
        list(LENGTH OPENSSL_SSL_RUNTIME_CANDIDATES OPENSSL_SSL_RUNTIME_CANDIDATE_COUNT)
        list(LENGTH OPENSSL_CRYPTO_RUNTIME_CANDIDATES OPENSSL_CRYPTO_RUNTIME_CANDIDATE_COUNT)
        if(NOT OPENSSL_SSL_RUNTIME_CANDIDATE_COUNT EQUAL 1 OR NOT OPENSSL_CRYPTO_RUNTIME_CANDIDATE_COUNT EQUAL 1)
            message(FATAL_ERROR "Unable to locate prebuilt OpenSSL runtime libraries in ${OPENSSL_DIR}/bin")
        endif()
        list(GET OPENSSL_SSL_RUNTIME_CANDIDATES 0 OPENSSL_SSL_RUNTIME_LOCATION)
        list(GET OPENSSL_CRYPTO_RUNTIME_CANDIDATES 0 OPENSSL_CRYPTO_RUNTIME_LOCATION)
        partout_import_openssl_targets(
            "${OPENSSL_SSL_RUNTIME_LOCATION}"
            "${OPENSSL_CRYPTO_RUNTIME_LOCATION}"
            "${OPENSSL_DIR}/${OPENSSL_SSL_IMPORT_LIBRARY}"
            "${OPENSSL_DIR}/${OPENSSL_CRYPTO_IMPORT_LIBRARY}"
        )
    else()
        partout_find_openssl_runtime(OPENSSL_SSL_RUNTIME_LOCATION "${OPENSSL_DIR}/${OPENSSL_LIBDIR}" libssl)
        partout_find_openssl_runtime(OPENSSL_CRYPTO_RUNTIME_LOCATION "${OPENSSL_DIR}/${OPENSSL_LIBDIR}" libcrypto)
        partout_import_openssl_targets(
            "${OPENSSL_SSL_RUNTIME_LOCATION}"
            "${OPENSSL_CRYPTO_RUNTIME_LOCATION}"
            ""
            ""
        )
    endif()

    add_library(OpenSSLInterface INTERFACE)
    target_include_directories(OpenSSLInterface INTERFACE ${OPENSSL_DIR}/include)
    target_link_libraries(OpenSSLInterface INTERFACE
        OpenSSL::SSL
        OpenSSL::Crypto
    )
    return()
endif()

# Configure flags
set(OPENSSL_CFG_FLAGS no-apps no-docs no-dsa no-engine no-gost no-legacy shared no-ssl no-tests no-zlib)

# Add some flags if -DANDROID
if(WIN32)
    if(ARCH_NAME MATCHES "^(arm64|aarch64)$")
        set(OPENSSL_TARGET "VC-WIN64-ARM")
    else()
        set(OPENSSL_TARGET "VC-WIN64A")
    endif()
elseif(ANDROID)
    set(OPENSSL_TARGET "android-arm64")
    if(DEFINED ANDROID_NATIVE_API_LEVEL)
        set(OPENSSL_ANDROID_API "${ANDROID_NATIVE_API_LEVEL}")
    elseif(DEFINED CMAKE_SYSTEM_VERSION)
        set(OPENSSL_ANDROID_API "${CMAKE_SYSTEM_VERSION}")
    endif()
    if(OPENSSL_ANDROID_API)
        list(APPEND OPENSSL_CFG_FLAGS "-D__ANDROID_API__=${OPENSSL_ANDROID_API}")
    endif()
    list(APPEND VENDOR_ENV ANDROID_NDK_ROOT=${CMAKE_ANDROID_NDK})
else()
    set(OPENSSL_TARGET "")
endif()

set(CFG_ARGS
    ${OPENSSL_TARGET}
    --prefix=${OPENSSL_DIR}
    --openssldir=${OPENSSL_DIR}
    --libdir=${OPENSSL_LIBDIR}
    ${OPENSSL_SYMBOLS}
    ${OPENSSL_CFG_FLAGS}
)
set(OPENSSL_BUILD_COMMAND ${VENDOR_ENV} ${MAKE_CMD})
if(NOT WIN32)
    include(ProcessorCount)
    ProcessorCount(OPENSSL_BUILD_JOBS)
    if(NOT OPENSSL_BUILD_JOBS EQUAL 0)
        list(APPEND OPENSSL_BUILD_COMMAND "-j${OPENSSL_BUILD_JOBS}")
    endif()
endif()
set(OPENSSL_INSTALL_COMMAND ${VENDOR_ENV} ${MAKE_CMD} install_sw)
if(APPLE)
    list(APPEND OPENSSL_INSTALL_COMMAND
        COMMAND install_name_tool -id "@rpath/libcrypto.3.dylib" "${OPENSSL_DIR}/${OPENSSL_LIBDIR}/libcrypto.3.dylib"
        COMMAND install_name_tool -id "@rpath/libssl.3.dylib" "${OPENSSL_DIR}/${OPENSSL_LIBDIR}/libssl.3.dylib"
        COMMAND install_name_tool -change
            "${OPENSSL_DIR}/${OPENSSL_LIBDIR}/libcrypto.3.dylib"
            "@rpath/libcrypto.3.dylib"
            "${OPENSSL_DIR}/${OPENSSL_LIBDIR}/libssl.3.dylib"
    )
endif()
ExternalProject_Add(OpenSSLProject
    SOURCE_DIR ${OPENSSL_BUILD_SOURCE_DIR}
    DOWNLOAD_COMMAND
        ${CMAKE_COMMAND} -E rm -rf ${OPENSSL_BUILD_SOURCE_DIR}
        COMMAND ${CMAKE_COMMAND} -E copy_directory ${OPENSSL_SOURCE_DIR} ${OPENSSL_BUILD_SOURCE_DIR}
    CONFIGURE_COMMAND ${VENDOR_ENV} perl ${OPENSSL_BUILD_SOURCE_DIR}/Configure ${CFG_ARGS}
    BUILD_COMMAND ${OPENSSL_BUILD_COMMAND}
    INSTALL_COMMAND ${OPENSSL_INSTALL_COMMAND}
    INSTALL_DIR ${OPENSSL_DIR}
    BUILD_IN_SOURCE 1
    BUILD_BYPRODUCTS ${OPENSSL_BYPRODUCTS}
)

# XXX: Use absolute paths to fix linking clash with system OpenSSL/BoringSSL
ExternalProject_Get_Property(OpenSSLProject install_dir)
if(WIN32)
    partout_import_openssl_targets(
        "${install_dir}/${OPENSSL_SSL_RUNTIME_LIBRARY}"
        "${install_dir}/${OPENSSL_CRYPTO_RUNTIME_LIBRARY}"
        "${install_dir}/${OPENSSL_SSL_IMPORT_LIBRARY}"
        "${install_dir}/${OPENSSL_CRYPTO_IMPORT_LIBRARY}"
    )
else()
    partout_import_openssl_targets(
        "${install_dir}/${OPENSSL_SSL_RUNTIME_LIBRARY}"
        "${install_dir}/${OPENSSL_CRYPTO_RUNTIME_LIBRARY}"
        ""
        ""
    )
endif()
add_dependencies(OpenSSL::SSL OpenSSLProject)
add_dependencies(OpenSSL::Crypto OpenSSLProject)

add_library(OpenSSLInterface INTERFACE)
add_dependencies(OpenSSLInterface OpenSSLProject)
target_include_directories(OpenSSLInterface INTERFACE ${install_dir}/include)
target_link_libraries(OpenSSLInterface INTERFACE
    OpenSSL::SSL
    OpenSSL::Crypto
)
