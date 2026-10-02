include("${CMAKE_CURRENT_LIST_DIR}/prebuilt.cmake")

set(PP_BUILD_VENDOR_PREBUILT_URL "" CACHE STRING
    "Root URL containing prebuilt vendor archives")

string(TOLOWER "${CMAKE_SYSTEM_NAME}" PLATFORM_NAME)
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" ARCH_NAME)
if(WIN32)
    if(CMAKE_C_COMPILER_ARCHITECTURE_ID)
        string(TOLOWER "${CMAKE_C_COMPILER_ARCHITECTURE_ID}" ARCH_NAME)
    elseif(DEFINED ENV{VSCMD_ARG_TGT_ARCH})
        string(TOLOWER "$ENV{VSCMD_ARG_TGT_ARCH}" ARCH_NAME)
    endif()
    if(ARCH_NAME MATCHES "^(x64|x86_64|amd64)(-|$)")
        set(ARCH_NAME amd64)
    elseif(ARCH_NAME MATCHES "^(arm64|aarch64)(-|$)")
        set(ARCH_NAME arm64)
    endif()
endif()

set(PP_BUILD_OUTPUT "${CMAKE_CURRENT_SOURCE_DIR}/bin/${PLATFORM_NAME}-${ARCH_NAME}"
    CACHE PATH "Build output directory")
file(TO_CMAKE_PATH "${PP_BUILD_OUTPUT}" PP_BUILD_OUTPUT)

if(APPLE OR CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PP_SYSTEM_VENDORS_AVAILABLE ON)
else()
    set(PP_SYSTEM_VENDORS_AVAILABLE OFF)
endif()

if(APPLE)
    find_program(HOMEBREW_EXECUTABLE brew)
endif()

function(partout_use_homebrew_formula formula)
    if(NOT HOMEBREW_EXECUTABLE)
        return()
    endif()
    execute_process(
        COMMAND "${HOMEBREW_EXECUTABLE}" --prefix "${formula}"
        RESULT_VARIABLE result
        OUTPUT_VARIABLE prefix
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
    if(result EQUAL 0)
        list(PREPEND CMAKE_PREFIX_PATH "${prefix}")
        set(CMAKE_PREFIX_PATH "${CMAKE_PREFIX_PATH}" PARENT_SCOPE)
    endif()
endfunction()
