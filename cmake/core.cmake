if(NOT PP_BUILD_LIBRARY)
    return()
endif()

if(WIN32 AND NOT MSVC)
    message(FATAL_ERROR "The Windows core DLL requires MSVC")
endif()
set(PARTOUT_ZIG_PREFIX "${CMAKE_CURRENT_BINARY_DIR}/zig-core")

# Build options and enabled backends.
set(PARTOUT_ZIG_ARGS build install
    --prefix "${PARTOUT_ZIG_PREFIX}"
    "-Drelease=$<IF:$<CONFIG:Debug>,false,true>"
    "-Dstrip=$<IF:$<CONFIG:Debug,RelWithDebInfo>,false,true>"
)

if(PP_BUILD_USE_OPENSSL)
    list(APPEND PARTOUT_ZIG_ARGS
        "-Dopenssl-include=${PARTOUT_OPENSSL_INCLUDE_DIR}"
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
    )
endif()

if(PP_BUILD_USE_OPENVPN)
    list(APPEND PARTOUT_ZIG_ARGS -Dopenvpn=true)
endif()

if(PP_BUILD_USE_WIREGUARD)
    list(APPEND PARTOUT_ZIG_ARGS
        -Dwireguard=true
        "-Dwg-go-include=${wg_source}/include"
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
cc_dir=${CMAKE_SYSROOT}/usr/lib/${CMAKE_LIBRARY_ARCHITECTURE}/${PARTOUT_ANDROID_API}
darwin_sdk_dir=
"
    )
    list(APPEND PARTOUT_ZIG_ARGS "-Dlibc-file=${PARTOUT_ZIG_LIBC}")
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
    list(APPEND PARTOUT_ZIG_ARGS "-Dapple-sdk-path=${PARTOUT_APPLE_SDK}")
elseif(WIN32)
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-windows-msvc")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(PARTOUT_ZIG_TARGET "${PARTOUT_ZIG_ARCH}-linux-gnu")
endif()
if(PARTOUT_ZIG_TARGET)
    list(APPEND PARTOUT_ZIG_ARGS "-Dtarget=${PARTOUT_ZIG_TARGET}")
endif()

if(PP_BUILD_WINDOWS)
    list(APPEND PARTOUT_ZIG_ARGS -Dwindows=true)
endif()
# Zig compiles the static core; CMake owns the final shared library.
find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)
set(PARTOUT_ZIG_LIBRARY "${PARTOUT_ZIG_PREFIX}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}partout${CMAKE_STATIC_LIBRARY_SUFFIX}")
add_custom_target(partout-zig ALL
    COMMAND "${PARTOUT_ZIG_EXECUTABLE}" ${PARTOUT_ZIG_ARGS}
    BYPRODUCTS ${PARTOUT_ZIG_LIBRARY}
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    USES_TERMINAL
    COMMAND_EXPAND_LISTS
    VERBATIM
)
set_source_files_properties("${PARTOUT_ZIG_LIBRARY}" PROPERTIES GENERATED TRUE)
add_library(partout SHARED "${PARTOUT_ZIG_LIBRARY}")
set_target_properties(partout PROPERTIES
    LINKER_LANGUAGE C
    LIBRARY_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib/$<0:>"
    RUNTIME_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
    ARCHIVE_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib/$<0:>"
    LINK_DEPENDS "${PARTOUT_ZIG_LIBRARY}"
)
add_dependencies(partout partout-zig)
add_library(Partout::Partout ALIAS partout)
target_include_directories(partout INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(partout PRIVATE
    "$<LINK_LIBRARY:WHOLE_ARCHIVE,${PARTOUT_ZIG_LIBRARY}>"
    ${PARTOUT_CORE_LIBRARIES}
)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports" partout_exports REGEX "^_")
list(TRANSFORM partout_exports REPLACE "^_" "")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS src/partout.exports)

if(APPLE)
    set(PP_BUILD_APPLE_INSTALL_NAME "@rpath/libpartout.dylib" CACHE STRING
        "Install name for the Apple shared library"
    )
    set_target_properties(partout PROPERTIES NO_SONAME TRUE)
    target_link_options(partout PRIVATE
        "LINKER:-install_name,${PP_BUILD_APPLE_INSTALL_NAME}"
        "LINKER:-compatibility_version,1.0.0" "LINKER:-current_version,1.0.0"
        "LINKER:-dead_strip" "LINKER:-rpath,@loader_path"
        "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports"
    )
    set_property(TARGET partout APPEND PROPERTY LINK_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports"
    )
    target_link_libraries(partout PRIVATE "-framework CoreFoundation" "-framework Security")
endif()

if(WIN32)
    # With no native object files, MSVC cannot infer the machine from the Zig
    # archive passed through /WHOLEARCHIVE.
    target_link_options(partout PRIVATE "LINKER:/MACHINE:${CMAKE_C_COMPILER_ARCHITECTURE_ID}")
    set_target_properties(partout PROPERTIES
        PDB_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
        WINDOWS_EXPORT_ALL_SYMBOLS OFF
    )
    # The core DLL exports only the public Zig/C ABI.
    foreach(symbol IN LISTS partout_exports)
        target_link_options(partout PRIVATE "LINKER:/EXPORT:${symbol}")
    endforeach()
    target_link_libraries(partout PRIVATE msvcrt bcrypt ole32 ws2_32 ntdll)
    if(PP_BUILD_WINDOWS)
        target_link_libraries(partout PRIVATE partout-windows-backend)
    endif()
elseif(NOT APPLE)
    find_package(Threads REQUIRED)
    target_link_libraries(partout PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
    set_target_properties(partout PROPERTIES BUILD_RPATH "$ORIGIN" INSTALL_RPATH "$ORIGIN")
    if(ANDROID)
        target_link_libraries(partout PRIVATE android)
    endif()
    list(JOIN partout_exports "; " partout_elf_exports)
    file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/partout.map"
        CONTENT "{ global: @partout_elf_exports@; local: *; };\n" @ONLY
    )
    target_link_options(partout PRIVATE "LINKER:-z,defs"
        "LINKER:--version-script,${CMAKE_CURRENT_BINARY_DIR}/partout.map"
    )
    set_property(TARGET partout APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/partout.map")
endif()
