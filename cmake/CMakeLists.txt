cmake_minimum_required(VERSION 3.27)
project(PartoutProject LANGUAGES Swift C CXX)

set(PARTOUT_DIR ${CMAKE_SOURCE_DIR}/..)

include(partout-core.cmake)
include(partout-c.cmake)
include(partout.cmake)

# Output to root
set(PARTOUT_OUTPUT ${PARTOUT_DIR}/${PP_BUILD_OUTPUT})
set_target_properties(partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${PARTOUT_OUTPUT}
    ARCHIVE_OUTPUT_DIRECTORY ${PARTOUT_OUTPUT}
    RUNTIME_OUTPUT_DIRECTORY ${PARTOUT_OUTPUT}
)

# Mind platform differences about static libraries
function(add_static_lib dir name out_list)
    if(WIN32)
        set(lib_path ${dir}/lib${name}.lib)
    elseif(APPLE)
        set(lib_path ${dir}/lib${name}.a)
    else()
        set(lib_path ${dir}/lib${name}.a)
    endif()
    set(${out_list} ${${out_list}} ${lib_path} PARENT_SCOPE)
endfunction()

# Link to vendor-specific dependencies
set(PARTOUT_LIBS)
if(DEFINED OPENSSL_DIR)
    target_include_directories(partout_c PRIVATE
        ${PARTOUT_DIR}/Sources/Crypto/CryptoOpenSSL_C/include
        ${PARTOUT_DIR}/Sources/Crypto/TLSOpenSSL_C/include
        ${OPENSSL_DIR}/include
    )
    add_static_lib(${OPENSSL_DIR}/lib ssl PARTOUT_LIBS)
    add_static_lib(${OPENSSL_DIR}/lib crypto PARTOUT_LIBS)
endif()
if(DEFINED MBEDTLS_DIR)
    target_include_directories(partout_c PRIVATE
        ${PARTOUT_DIR}/Sources/Crypto/CryptoMbedTLS_C/include
        ${PARTOUT_DIR}/Sources/Crypto/TLSMbedTLS_C/include
        ${MBEDTLS_DIR}/include
    )
    add_static_lib(${MBEDTLS_DIR}/lib mbedcrypto PARTOUT_LIBS)
    add_static_lib(${MBEDTLS_DIR}/lib mbedtls PARTOUT_LIBS)
    add_static_lib(${MBEDTLS_DIR}/lib mbedx509 PARTOUT_LIBS)
endif()
target_link_libraries(partout_c PRIVATE
    ${PARTOUT_LIBS}
)
