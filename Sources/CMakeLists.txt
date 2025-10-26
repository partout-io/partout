cmake_minimum_required(VERSION 3.27)
project(PartoutProject LANGUAGES Swift C CXX)

# One include per Swift target
include(partout-c.cmake)
include(partout.cmake)

# Set output from flag
set(OUTPUT_DIR ${CMAKE_SOURCE_DIR}/../${PP_BUILD_OUTPUT})
set_target_properties(partout PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_DIR}
)

# Mind platform differences about libraries
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
        ${OPENSSL_DIR}/include
    )
    add_static_lib(${OPENSSL_DIR}/lib ssl PARTOUT_LIBS)
    add_static_lib(${OPENSSL_DIR}/lib crypto PARTOUT_LIBS)
elseif(DEFINED MBEDTLS_DIR)
    target_include_directories(partout_c PRIVATE
        ${MBEDTLS_DIR}/include
    )
    list(APPEND ${PARTOUT_LIBS}
        ${MBEDTLS_DIR}/lib/mbedcrypto
        ${MBEDTLS_DIR}/lib/mbedtls
        ${MBEDTLS_DIR}/lib/mbedx509
    )
endif()
if(DEFINED WGGO_DIR)
    target_include_directories(partout_c PRIVATE
        ${WGGO_DIR}/include
        ${CMAKE_SOURCE_DIR}/PartoutWireGuard/Shared_C/include
    )
    # Do not link dynamic library
endif()
target_link_libraries(partout_c PRIVATE
    ${PARTOUT_LIBS}
)
