include("${CMAKE_CURRENT_LIST_DIR}/prebuilt.cmake")

set(PP_BUILD_VENDOR_PREBUILT_URL "" CACHE STRING
    "Root URL containing prebuilt vendor archives")

string(TOLOWER "${CMAKE_SYSTEM_NAME}" PLATFORM_NAME)
string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" ARCH_NAME)
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
    list(LENGTH CMAKE_OSX_ARCHITECTURES arch_count)
    if(NOT arch_count EQUAL 1)
        message(FATAL_ERROR "Build one Apple architecture at a time; combine slices with lipo")
    endif()
    set(ARCH_NAME "${CMAKE_OSX_ARCHITECTURES}")
endif()
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

set(PARTOUT_ZIG_ARCH "${ARCH_NAME}")
if(PARTOUT_ZIG_ARCH MATCHES "^(arm64|aarch64)$")
    set(PARTOUT_ZIG_ARCH aarch64)
elseif(PARTOUT_ZIG_ARCH MATCHES "^(x64|x86_64|amd64)$")
    set(PARTOUT_ZIG_ARCH x86_64)
endif()

if(ANDROID)
    string(REGEX REPLACE "^android-" "" PARTOUT_ANDROID_API "${ANDROID_PLATFORM}")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-android.${PARTOUT_ANDROID_API}")
    set(PARTOUT_ZIG_LIBC "${CMAKE_CURRENT_BINARY_DIR}/android.libc")
    file(WRITE "${PARTOUT_ZIG_LIBC}"
"include_dir=${CMAKE_SYSROOT}/usr/include
sys_include_dir=${CMAKE_SYSROOT}/usr/include/${CMAKE_LIBRARY_ARCHITECTURE}
crt_dir=${CMAKE_SYSROOT}/usr/lib/${CMAKE_LIBRARY_ARCHITECTURE}/${PARTOUT_ANDROID_API}
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
")
elseif(APPLE)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(PARTOUT_APPLE_OS ios)
        set(apple_sdk iphoneos)
        set(apple_minimum 16.0)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "tvOS")
        set(PARTOUT_APPLE_OS tvos)
        set(apple_sdk appletvos)
        set(apple_minimum 17.0)
    else()
        set(PARTOUT_APPLE_OS macos)
        set(apple_sdk macosx)
        set(apple_minimum 13.0)
    endif()
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        set(apple_minimum "${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    if(CMAKE_OSX_SYSROOT)
        set(apple_sdk "${CMAKE_OSX_SYSROOT}")
    endif()
    execute_process(COMMAND xcrun --sdk "${apple_sdk}" --show-sdk-path
        OUTPUT_VARIABLE PARTOUT_APPLE_SDK OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY)
    set(apple_simulator "")
    if(PARTOUT_APPLE_SDK MATCHES "[Ss]imulator")
        set(apple_simulator "-simulator")
    endif()
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-${PARTOUT_APPLE_OS}.${apple_minimum}${apple_simulator}")
    if(PARTOUT_ZIG_ARCH STREQUAL "aarch64")
        set(apple_arch arm64)
    else()
        set(apple_arch "${PARTOUT_ZIG_ARCH}")
    endif()
    set(PARTOUT_APPLE_TARGET "${apple_arch}-apple-${PARTOUT_APPLE_OS}${apple_minimum}${apple_simulator}")
elseif(WIN32)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-windows-msvc")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-gnu")
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
