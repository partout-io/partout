set(PARTOUT_MBEDTLS_DEPENDENCY "")

if(PP_USE_SYSTEM_VENDORS)
    partout_use_homebrew_formula(mbedtls)
    find_path(PARTOUT_MBEDTLS_INCLUDE_DIR mbedtls/ssl.h)
    find_library(PARTOUT_MBEDTLS_TLS_LIBRARY mbedtls)
    find_library(PARTOUT_MBEDTLS_X509_LIBRARY mbedx509)
    find_library(PARTOUT_MBEDTLS_CRYPTO_LIBRARY mbedcrypto)
    if(NOT PARTOUT_MBEDTLS_INCLUDE_DIR OR
       NOT PARTOUT_MBEDTLS_TLS_LIBRARY OR
       NOT PARTOUT_MBEDTLS_X509_LIBRARY OR
       NOT PARTOUT_MBEDTLS_CRYPTO_LIBRARY)
        message(FATAL_ERROR "System MbedTLS not found")
    endif()

    get_filename_component(PARTOUT_MBEDTLS_LIBRARY_DIR "${PARTOUT_MBEDTLS_TLS_LIBRARY}" DIRECTORY)
    foreach(library IN ITEMS PARTOUT_MBEDTLS_X509_LIBRARY PARTOUT_MBEDTLS_CRYPTO_LIBRARY)
        get_filename_component(library_dir "${${library}}" DIRECTORY)
        if(NOT library_dir STREQUAL PARTOUT_MBEDTLS_LIBRARY_DIR)
            message(FATAL_ERROR "System MbedTLS libraries must be in the same directory")
        endif()
    endforeach()

    message(STATUS "Using system MbedTLS")
    return()
endif()

set(MBEDTLS_DIR "${PP_BUILD_OUTPUT}/mbedtls")
set(PARTOUT_MBEDTLS_INCLUDE_DIR "${MBEDTLS_DIR}/include")
set(PARTOUT_MBEDTLS_LIBRARY_DIR "${MBEDTLS_DIR}/lib")

if(PP_USE_PREBUILT_VENDORS)
    partout_use_prebuilt_vendor(mbedtls MBEDTLS_DIR)
    return()
endif()

set(MBEDTLS_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendors/mbedtls")
set(MBEDTLS_PYTHON_VENV "${PP_BUILD_OUTPUT}/mbedtls-python")
if(WIN32)
    set(MBEDTLS_PYTHON "${MBEDTLS_PYTHON_VENV}/Scripts/python.exe")
else()
    set(MBEDTLS_PYTHON "${MBEDTLS_PYTHON_VENV}/bin/python")
endif()

set(MBEDTLS_REQUIREMENTS
    "${MBEDTLS_SOURCE_DIR}/scripts/basic.requirements.txt"
    "${MBEDTLS_SOURCE_DIR}/tf-psa-crypto/scripts/basic.requirements.txt"
)
set(MBEDTLS_REQUIREMENTS_DEPENDS
    ${MBEDTLS_REQUIREMENTS}
    "${MBEDTLS_SOURCE_DIR}/scripts/driver.requirements.txt"
    "${MBEDTLS_SOURCE_DIR}/tf-psa-crypto/scripts/driver.requirements.txt"
)
set(MBEDTLS_PYTHON_STAMP "${MBEDTLS_PYTHON_VENV}/.requirements.stamp")

find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_custom_command(
    OUTPUT "${MBEDTLS_PYTHON_STAMP}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${PP_BUILD_OUTPUT}"
    COMMAND "${Python3_EXECUTABLE}" -m venv "${MBEDTLS_PYTHON_VENV}"
    COMMAND "${MBEDTLS_PYTHON}" -m pip install --disable-pip-version-check
        -r "${MBEDTLS_SOURCE_DIR}/scripts/basic.requirements.txt"
        -r "${MBEDTLS_SOURCE_DIR}/tf-psa-crypto/scripts/basic.requirements.txt"
    COMMAND "${CMAKE_COMMAND}" -E touch "${MBEDTLS_PYTHON_STAMP}"
    DEPENDS ${MBEDTLS_REQUIREMENTS_DEPENDS}
    VERBATIM
)
add_custom_target(MbedTLSPython DEPENDS "${MBEDTLS_PYTHON_STAMP}")

set(MBEDTLS_CMAKE_ARGS
    "-DCMAKE_INSTALL_PREFIX=${MBEDTLS_DIR}"
    "-DPython3_EXECUTABLE=${MBEDTLS_PYTHON}"
    -DGEN_FILES=ON
    -DENABLE_PROGRAMS=OFF
    -DENABLE_TESTING=OFF
)
if(CMAKE_BUILD_TYPE)
    list(APPEND MBEDTLS_CMAKE_ARGS "-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}")
endif()

if(WIN32)
    list(APPEND MBEDTLS_CMAKE_ARGS
        -DCMAKE_POLICY_DEFAULT_CMP0091=NEW
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=${CMAKE_MSVC_RUNTIME_LIBRARY}"
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF
        -DUSE_STATIC_MBEDTLS_LIBRARY=ON
    )

    set(MBEDTLS_NORMALIZE_CRYPTO_LIBRARY_SCRIPT
        "${CMAKE_CURRENT_BINARY_DIR}/vendors/mbedtls-normalize-crypto.cmake")
    file(WRITE "${MBEDTLS_NORMALIZE_CRYPTO_LIBRARY_SCRIPT}" [=[
set(mbedcrypto_lib "${MBEDTLS_DIR}/lib/mbedcrypto.lib")
set(mbedcrypto_archive "${MBEDTLS_DIR}/lib/libmbedcrypto.a")
if(NOT EXISTS "${mbedcrypto_lib}" AND EXISTS "${mbedcrypto_archive}")
    file(COPY_FILE "${mbedcrypto_archive}" "${mbedcrypto_lib}" ONLY_IF_DIFFERENT)
endif()
]=])
    set(MBEDTLS_INSTALL_COMMAND
        INSTALL_COMMAND "${CMAKE_COMMAND}" --build <BINARY_DIR> --target install ${PP_BUILD_CONFIG_ARGS}
        COMMAND "${CMAKE_COMMAND}" "-DMBEDTLS_DIR=${MBEDTLS_DIR}"
            -P "${MBEDTLS_NORMALIZE_CRYPTO_LIBRARY_SCRIPT}"
    )
elseif(ANDROID)
    list(APPEND MBEDTLS_CMAKE_ARGS
        "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_ANDROID_NDK}/build/cmake/android.toolchain.cmake"
        "-DCMAKE_ANDROID_NDK=${CMAKE_ANDROID_NDK}"
        "-DANDROID_ABI=${ANDROID_ABI}"
        "-DANDROID_PLATFORM=${ANDROID_PLATFORM}"
        "-DANDROID_STL=${ANDROID_STL}"
    )
endif()

ExternalProject_Add(MbedTLSProject
    SOURCE_DIR "${MBEDTLS_SOURCE_DIR}"
    DEPENDS MbedTLSPython
    CMAKE_ARGS ${MBEDTLS_CMAKE_ARGS}
    ${MBEDTLS_INSTALL_COMMAND}
)
set(PARTOUT_MBEDTLS_DEPENDENCY MbedTLSProject)
