cmake_minimum_required(VERSION 3.27)
project(PartoutProject LANGUAGES Swift C CXX)

# One include per Swift target
include(partout-c.cmake)
include(partout.cmake)

# Set output from flag
set(OUTPUT_DIR ${CMAKE_SOURCE_DIR}/../${PP_BUILD_OUTPUT})
set_target_properties(Partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_DIR}
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
    target_include_directories(Partout_C PRIVATE
        ${CMAKE_SOURCE_DIR}/Crypto/CryptoOpenSSL_C/include
        ${CMAKE_SOURCE_DIR}/Crypto/TLSOpenSSL_C/include
        ${OPENSSL_DIR}/include
    )
    add_static_lib(${OPENSSL_DIR}/lib ssl PARTOUT_LIBS)
    add_static_lib(${OPENSSL_DIR}/lib crypto PARTOUT_LIBS)
endif()
if(DEFINED MBEDTLS_DIR)
    target_include_directories(Partout_C PRIVATE
        ${CMAKE_SOURCE_DIR}/Crypto/CryptoMbedTLS_C/include
        ${CMAKE_SOURCE_DIR}/Crypto/TLSMbedTLS_C/include
        ${MBEDTLS_DIR}/include
    )
    add_static_lib(${MBEDTLS_DIR}/lib mbedcrypto PARTOUT_LIBS)
    add_static_lib(${MBEDTLS_DIR}/lib mbedtls PARTOUT_LIBS)
    add_static_lib(${MBEDTLS_DIR}/lib mbedx509 PARTOUT_LIBS)
endif()
target_link_libraries(Partout_C PRIVATE
    ${PARTOUT_LIBS}
)
