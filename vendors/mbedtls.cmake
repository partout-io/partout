set(MBEDTLS_DIR ${PP_BUILD_OUTPUT}/mbedtls)

# Output
if(WIN32)
    set(LIBTLS library/libmbedtls${LIBEXT})
    set(LIBX509 library/libmbedx509${LIBEXT})
    set(LIBCRYPTO library/libmbedcrypto${LIBEXT})
    set(LIBTLS_IMP library/libmbedtls${LIBEXT_IMP})
    set(LIBX509_IMP library/libmbedx509${LIBEXT_IMP})
    set(LIBCRYPTO_IMP library/libmbedcrypto${LIBEXT_IMP})
else()
    set(LIBTLS library/libmbedtls${LIBEXT})
    set(LIBX509 library/libmbedx509${LIBEXT})
    set(LIBCRYPTO library/libmbedcrypto${LIBEXT})
endif()

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
add_library(MbedTLS::TLS SHARED IMPORTED GLOBAL)
add_library(MbedTLS::X509 SHARED IMPORTED GLOBAL)
add_library(MbedTLS::Crypto SHARED IMPORTED GLOBAL)
if(WIN32)
    set_target_properties(MbedTLS::TLS PROPERTIES
        IMPORTED_LOCATION ${install_dir}/${LIBTLS}
        IMPORTED_IMPLIB ${install_dir}/${LIBTLS_IMP}
    )
    set_target_properties(MbedTLS::X509 PROPERTIES
        IMPORTED_LOCATION ${install_dir}/${LIBX509}
        IMPORTED_IMPLIB ${install_dir}/${LIBX509_IMP}
    )
    set_target_properties(MbedTLS::Crypto PROPERTIES
        IMPORTED_LOCATION ${install_dir}/${LIBCRYPTO}
        IMPORTED_IMPLIB ${install_dir}/${LIBCRYPTO_IMP}
    )
else()
    set_target_properties(MbedTLS::TLS PROPERTIES
        IMPORTED_LOCATION ${install_dir}/${LIBTLS}
    )
    set_target_properties(MbedTLS::X509 PROPERTIES
        IMPORTED_LOCATION ${install_dir}/${LIBX509}
    )
    set_target_properties(MbedTLS::Crypto PROPERTIES
        IMPORTED_LOCATION ${install_dir}/${LIBCRYPTO}
    )
endif()
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
