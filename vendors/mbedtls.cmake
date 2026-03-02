set(MBEDTLS_DIR ${PP_BUILD_OUTPUT}/mbedtls)

ExternalProject_Add(MbedTLSProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls
    CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${MBEDTLS_DIR}
    INSTALL_DIR ${MBEDTLS_DIR}
    BUILD_BYPRODUCTS
        <INSTALL_DIR>/lib/libmbedtls.${LIBEXT}
        <INSTALL_DIR>/lib/libmbedx509.${LIBEXT}
        <INSTALL_DIR>/lib/libmbedcrypto.${LIBEXT}
)

ExternalProject_Get_Property(MbedTLSProject install_dir)
add_library(MbedTLS::TLS SHARED IMPORTED GLOBAL)
add_library(MbedTLS::X509 SHARED IMPORTED GLOBAL)
add_library(MbedTLS::Crypto SHARED IMPORTED GLOBAL)
set_target_properties(MbedTLS::TLS PROPERTIES
    IMPORTED_LOCATION ${install_dir}/lib/libmbedtls.${LIBEXT}
)
set_target_properties(MbedTLS::X509 PROPERTIES
    IMPORTED_LOCATION ${install_dir}/lib/libmbedx509.${LIBEXT}
)
set_target_properties(MbedTLS::Crypto PROPERTIES
    IMPORTED_LOCATION ${install_dir}/lib/libmbedcrypto.${LIBEXT}
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
