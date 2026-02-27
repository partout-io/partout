set(MBEDTLS_DIR ${PP_BUILD_OUTPUT}/mbedtls)

ExternalProject_Add(MbedTLSProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls
    CMAKE_ARGS -DCMAKE_INSTALL_PREFIX=${MBEDTLS_DIR}
)

add_library(MbedTLSInterface INTERFACE)
add_dependencies(MbedTLSInterface MbedTLSProject)
target_include_directories(MbedTLSInterface INTERFACE ${MBEDTLS_DIR}/include)
target_link_directories(MbedTLSInterface INTERFACE ${MBEDTLS_DIR}/lib)
target_link_libraries(MbedTLSInterface INTERFACE mbedtls mbedx509 mbedcrypto)
