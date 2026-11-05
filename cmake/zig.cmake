if(NOT PP_BUILD_LIBRARY)
    return()
endif()

# Build options and enabled backends.
set(PARTOUT_ZIG_ARGS build install
    --prefix "${PP_BUILD_OUTPUT}/partout"
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    "-Dstrip=$<IF:$<CONFIG:Debug,RelWithDebInfo>,false,true>"
    "-Dshared=$<IF:$<BOOL:${APPLE}>,false,true>"
)

if(PP_BUILD_USE_OPENSSL)
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dopenssl-include=${PARTOUT_OPENSSL_INCLUDE_DIR}"
        "-Dopenssl-lib=${PARTOUT_OPENSSL_LIBRARY_DIR}"
    )
    if(PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR)
        list(APPEND PARTOUT_ZIG_ARGS
            "-Dopenssl-config-include=${PARTOUT_OPENSSL_CONFIG_INCLUDE_DIR}"
        )
    endif()
endif()

if(PP_BUILD_USE_MBEDTLS)
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dmbedtls-include=${PARTOUT_MBEDTLS_INCLUDE_DIR}"
        "-Dmbedtls-lib=${PARTOUT_MBEDTLS_LIBRARY_DIR}"
    )
endif()

if(PP_BUILD_USE_OPENVPN)
    list(APPEND PARTOUT_ZIG_ARGS -Dopenvpn=true)
endif()

if(PP_BUILD_USE_WIREGUARD)
    list(APPEND PARTOUT_ZIG_ARGS
        -Dwireguard=true
        "-Dwg-go-include=${wg_source}/include"
        "-Dwg-go-lib=${wg_work}/lib"
    )
endif()

# Target architecture, SDK, and libc.
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
    list(APPEND PARTOUT_ZIG_ARGS --libc "${PARTOUT_ZIG_LIBC}")
elseif(APPLE)
    if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(PARTOUT_APPLE_OS ios)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "tvOS")
        set(PARTOUT_APPLE_OS tvos)
    else()
        set(PARTOUT_APPLE_OS macos)
    endif()
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-${PARTOUT_APPLE_OS}")
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        string(APPEND PARTOUT_ZIG_TARGET ".${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    if(CMAKE_OSX_SYSROOT MATCHES "[Ss]imulator")
        string(APPEND PARTOUT_ZIG_TARGET "-simulator")
    endif()
    if(IS_DIRECTORY "${CMAKE_OSX_SYSROOT}")
        set(PARTOUT_APPLE_SDK "${CMAKE_OSX_SYSROOT}")
    else()
        execute_process(
            COMMAND xcrun --sdk macosx --show-sdk-path
            OUTPUT_VARIABLE PARTOUT_APPLE_SDK
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_QUIET
        )
    endif()
    if(PARTOUT_APPLE_SDK)
        list(APPEND PARTOUT_ZIG_ARGS "-Dapple-sdk-path=${PARTOUT_APPLE_SDK}")
    endif()
elseif(WIN32)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-windows-msvc")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-gnu")
endif()
if(PARTOUT_ZIG_TARGET)
    list(APPEND PARTOUT_ZIG_ARGS "-Dtarget=${PARTOUT_ZIG_TARGET}")
endif()

if(PP_BUILD_WINDOWS)
    list(APPEND PARTOUT_ZIG_ARGS "-Dwindows-lib=$<TARGET_LINKER_FILE:partout-windows-backend>")
endif()
# Compile the core; Apple links the resulting archive below.
find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)
if(WIN32)
    set(PARTOUT_LINK_LIBRARY "${PP_BUILD_OUTPUT}/partout/lib/partout.lib")
    set(PARTOUT_ZIG_BYPRODUCTS
        "${PARTOUT_LINK_LIBRARY}"
        "${PP_BUILD_OUTPUT}/partout/bin/partout.dll"
    )
else()
    set(PARTOUT_LINK_LIBRARY
        "${PP_BUILD_OUTPUT}/partout/lib/${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(PARTOUT_ZIG_BYPRODUCTS "${PARTOUT_LINK_LIBRARY}")
endif()

set(PARTOUT_COMPILE_TARGET partout)
if(APPLE)
    set(PARTOUT_COMPILE_TARGET partout-zig)
    set(PARTOUT_ZIG_BYPRODUCTS "${PP_BUILD_OUTPUT}/partout/lib/libpartout.a")
endif()
add_custom_target(${PARTOUT_COMPILE_TARGET} ALL
    COMMAND "${PARTOUT_ZIG_EXECUTABLE}" ${PARTOUT_ZIG_ARGS}
    BYPRODUCTS ${PARTOUT_ZIG_BYPRODUCTS}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMAND_EXPAND_LISTS
    VERBATIM
)
if(PP_BUILD_USE_WIREGUARD)
    add_dependencies(${PARTOUT_COMPILE_TARGET} partout-wg-go)
endif()
if(PP_BUILD_WINDOWS)
    add_dependencies(${PARTOUT_COMPILE_TARGET} partout-windows-backend)
endif()

if(APPLE)
    set(PP_BUILD_APPLE_INSTALL_NAME "@rpath/libpartout.dylib" CACHE STRING
        "Install name for the Apple shared library")
    set_source_files_properties(${PARTOUT_ZIG_BYPRODUCTS} PROPERTIES GENERATED TRUE)
    add_library(partout SHARED ${PARTOUT_ZIG_BYPRODUCTS})
    set_target_properties(partout PROPERTIES
        LINKER_LANGUAGE C
        LIBRARY_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib"
        OUTPUT_NAME partout
        NO_SONAME TRUE
    )
    add_dependencies(partout partout-zig)
    target_link_options(partout PRIVATE
        "LINKER:-install_name,${PP_BUILD_APPLE_INSTALL_NAME}"
        "LINKER:-compatibility_version,1.0.0" "LINKER:-current_version,1.0.0"
        "LINKER:-dead_strip" "LINKER:-rpath,@loader_path"
        "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports"
        "LINKER:-force_load,${PP_BUILD_OUTPUT}/partout/lib/libpartout.a"
    )
    set_property(TARGET partout APPEND PROPERTY LINK_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports" ${PARTOUT_ZIG_BYPRODUCTS})
    target_link_libraries(partout PRIVATE ${PARTOUT_APPLE_LIBRARIES}
        "-framework CoreFoundation" "-framework Security")
    if(PP_BUILD_USE_WIREGUARD)
        target_link_libraries(partout PRIVATE Partout::WireGuard)
    endif()
endif()

# Expose the core and its runtime dependencies to consumers.
file(MAKE_DIRECTORY "${PP_BUILD_OUTPUT}/partout/include")
add_library(Partout::Partout SHARED IMPORTED GLOBAL)
if(WIN32)
    set_target_properties(Partout::Partout PROPERTIES
        IMPORTED_IMPLIB "${PARTOUT_LINK_LIBRARY}"
        IMPORTED_LOCATION "${PP_BUILD_OUTPUT}/partout/bin/partout.dll"
    )
else()
    set_target_properties(Partout::Partout PROPERTIES
        IMPORTED_LOCATION "${PARTOUT_LINK_LIBRARY}"
        IMPORTED_SONAME "${CMAKE_SHARED_LIBRARY_PREFIX}partout${CMAKE_SHARED_LIBRARY_SUFFIX}"
    )
endif()
add_dependencies(Partout::Partout partout)
set_target_properties(Partout::Partout PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${PP_BUILD_OUTPUT}/partout/include"
    INTERFACE_LINK_LIBRARIES "${PARTOUT_RUNTIME_LIBRARIES}"
)
