set(PARTOUT_MBEDTLS_IS_SYSTEM OFF)
if(PARTOUT_SYSTEM_VENDOR_SEARCH)
    find_package(MbedTLS CONFIG QUIET)
    if(MbedTLS_FOUND AND TARGET MbedTLS::mbedtls AND TARGET MbedTLS::mbedx509 AND TARGET MbedTLS::mbedcrypto)
        set(PARTOUT_MBEDTLS_IS_SYSTEM ON)
        add_library(MbedTLSInterface INTERFACE)
        target_link_libraries(MbedTLSInterface INTERFACE
            MbedTLS::mbedtls
            MbedTLS::mbedx509
            MbedTLS::mbedcrypto
        )
        message(STATUS "Using system MbedTLS")
        return()
    endif()

    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(MBEDTLS_PKG QUIET IMPORTED_TARGET mbedtls mbedx509 mbedcrypto)
        if(MBEDTLS_PKG_FOUND AND TARGET PkgConfig::MBEDTLS_PKG)
            set(PARTOUT_MBEDTLS_IS_SYSTEM ON)
            add_library(MbedTLSInterface INTERFACE)
            target_link_libraries(MbedTLSInterface INTERFACE PkgConfig::MBEDTLS_PKG)
            message(STATUS "Using system MbedTLS")
            return()
        endif()
    endif()

    if(PARTOUT_SYSTEM_VENDOR_REQUIRED)
        message(FATAL_ERROR "System MbedTLS not found")
    endif()
endif()

set(MBEDTLS_DIR ${PP_BUILD_OUTPUT}/mbedtls)
set(MBEDTLS_PYTHON_VENV ${PP_BUILD_OUTPUT}/mbedtls-python)
set(MBEDTLS_PYTHON_REQUIREMENTS ${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls/tf-psa-crypto/scripts/basic.requirements.txt)
set(MBEDTLS_PYTHON_DRIVER_REQUIREMENTS ${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls/tf-psa-crypto/scripts/driver.requirements.txt)
set(MBEDTLS_PYTHON_STAMP ${MBEDTLS_PYTHON_VENV}/.requirements.stamp)
if(WIN32)
    set(MBEDTLS_PYTHON_EXECUTABLE ${MBEDTLS_PYTHON_VENV}/Scripts/python.exe)
else()
    set(MBEDTLS_PYTHON_EXECUTABLE ${MBEDTLS_PYTHON_VENV}/bin/python)
endif()

find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_custom_command(
    OUTPUT ${MBEDTLS_PYTHON_STAMP}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${PP_BUILD_OUTPUT}
    COMMAND ${Python3_EXECUTABLE} -m venv ${MBEDTLS_PYTHON_VENV}
    COMMAND ${MBEDTLS_PYTHON_EXECUTABLE} -m pip install --disable-pip-version-check -r ${MBEDTLS_PYTHON_REQUIREMENTS}
    COMMAND ${CMAKE_COMMAND} -E touch ${MBEDTLS_PYTHON_STAMP}
    DEPENDS
        ${MBEDTLS_PYTHON_REQUIREMENTS}
        ${MBEDTLS_PYTHON_DRIVER_REQUIREMENTS}
    VERBATIM
)
add_custom_target(MbedTLSPythonEnv DEPENDS ${MBEDTLS_PYTHON_STAMP})

# Output
set(LIBTLS lib/${LIBPFX_STATIC}mbedtls${LIBEXT_STATIC})
set(LIBX509 lib/${LIBPFX_STATIC}mbedx509${LIBEXT_STATIC})
set(LIBCRYPTO lib/${LIBPFX_STATIC}mbedcrypto${LIBEXT_STATIC})

set(MBEDTLS_CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=${MBEDTLS_DIR}
    -DPython3_EXECUTABLE=${MBEDTLS_PYTHON_EXECUTABLE}
    -DENABLE_PROGRAMS=OFF
    -DENABLE_TESTING=OFF
)
if(ANDROID)
    list(APPEND MBEDTLS_CMAKE_ARGS
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_ANDROID_NDK}/build/cmake/android.toolchain.cmake
        -DCMAKE_ANDROID_NDK=${CMAKE_ANDROID_NDK}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_PLATFORM=${ANDROID_PLATFORM}
        -DANDROID_STL=${ANDROID_STL}
    )
endif()

ExternalProject_Add(MbedTLSProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls
    DEPENDS MbedTLSPythonEnv
    CMAKE_ARGS ${MBEDTLS_CMAKE_ARGS}
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
