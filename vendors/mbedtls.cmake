set(MBEDTLS_DIR ${PP_BUILD_OUTPUT}/mbedtls)

# Output
set(LIBTLS lib/${LIBPFX_STATIC}mbedtls${LIBEXT_STATIC})
set(LIBX509 lib/${LIBPFX_STATIC}mbedx509${LIBEXT_STATIC})
set(LIBCRYPTO lib/${LIBPFX_STATIC}mbedcrypto${LIBEXT_STATIC})

ExternalProject_Add(MbedTLSProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls
    CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${MBEDTLS_DIR}
    INSTALL_DIR ${MBEDTLS_DIR}
    BUILD_BYPRODUCTS
        <INSTALL_DIR>/${LIBTLS}
        <INSTALL_DIR>/${LIBX509}
        <INSTALL_DIR>/${LIBCRYPTO}
)

ExternalProject_Get_Property(MbedTLSProject install_dir)
add_library(MbedTLS::TLS STATIC IMPORTED GLOBAL)
add_library(MbedTLS::X509 STATIC IMPORTED GLOBAL)
add_library(MbedTLS::Crypto STATIC IMPORTED GLOBAL)
set_target_properties(MbedTLS::TLS PROPERTIES
    IMPORTED_LOCATION ${install_dir}/${LIBTLS}
)
set_target_properties(MbedTLS::X509 PROPERTIES
    IMPORTED_LOCATION ${install_dir}/${LIBX509}
)
set_target_properties(MbedTLS::Crypto PROPERTIES
    IMPORTED_LOCATION ${install_dir}/${LIBCRYPTO}
)
add_dependencies(MbedTLS::TLS MbedTLSProject)
add_dependencies(MbedTLS::X509 MbedTLSProject)
add_dependencies(MbedTLS::Crypto MbedTLSProject)

add_library(MbedTLSInterface INTERFACE)
add_dependencies(MbedTLSInterface MbedTLSProject)
target_include_directories(MbedTLSInterface INTERFACE ${MBEDTLS_DIR}/include)
target_link_libraries(MbedTLSInterface INTERFACE
    MbedTLS::TLS
    MbedTLS::X509
    MbedTLS::Crypto
)
