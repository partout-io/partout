# SPDX-FileCopyrightText: 2026 Davide De Rosa
# SPDX-License-Identifier: GPL-3.0

if(NOT PP_BUILD_LIBRARY)
    return()
endif()

set_source_files_properties("${PARTOUT_ZIG_LIBRARY}" PROPERTIES GENERATED TRUE)
add_library(partout SHARED "${PARTOUT_ZIG_LIBRARY}")
if(MSVC)
    # Visual Studio needs a compiled source to run the DLL linker.
    set(partout_link_source "${CMAKE_CURRENT_BINARY_DIR}/PartoutLink.c")
    file(CONFIGURE OUTPUT "${partout_link_source}"
        CONTENT "typedef int PartoutLink;\n" @ONLY)
    target_sources(partout PRIVATE "${partout_link_source}")
endif()
set_target_properties(partout PROPERTIES
    LINKER_LANGUAGE C
    LIBRARY_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib/$<0:>"
    RUNTIME_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
    ARCHIVE_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/lib/$<0:>"
    LINK_DEPENDS "${PARTOUT_ZIG_LIBRARY}"
)
add_dependencies(partout partout-zig)
add_library(Partout::Partout ALIAS partout)
target_link_libraries(partout INTERFACE Partout::Headers)
target_link_libraries(partout PRIVATE
    "$<LINK_LIBRARY:WHOLE_ARCHIVE,${PARTOUT_ZIG_LIBRARY}>"
    ${PARTOUT_CORE_LIBRARIES}
)

# Embed static implementations in the shared library.
foreach(target IN LISTS partout_runtime_targets)
    set_target_properties(${target} PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON)
    target_link_libraries(partout PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,${target}>")
    foreach(property IN ITEMS INCLUDE_DIRECTORIES COMPILE_FEATURES COMPILE_DEFINITIONS LINK_LIBRARIES)
        get_target_property(requirements ${target} INTERFACE_${property})
        if(requirements)
            set_property(TARGET partout APPEND PROPERTY INTERFACE_${property} "${requirements}")
        endif()
    endforeach()
    if(MSVC)
        target_compile_definitions(${target} PRIVATE PARTOUT_API_BUILD_DLL)
    endif()
endforeach()

if(TARGET partout-cpp-runtime)
    set_target_properties(partout PROPERTIES LINKER_LANGUAGE CXX)
endif()

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.exports" partout_exports REGEX "^_")
list(TRANSFORM partout_exports REPLACE "^_" "")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS src/partout.exports)

if(PP_BUILD_WINTUN OR (UNIX AND NOT ANDROID))
    list(APPEND partout_exports partout_platform_bindings_init)
endif()

# Desktop exports use Zig export declarations and C++ PARTOUT_API visibility.
# A linker allowlist would hide the annotated C++ API as well.
if(APPLE)
    set(PP_BUILD_APPLE_INSTALL_NAME "@rpath/libpartout.dylib" CACHE STRING
        "Install name for the Apple shared library"
    )
    set_target_properties(partout PROPERTIES NO_SONAME TRUE)
    target_link_options(partout PRIVATE
        "LINKER:-install_name,${PP_BUILD_APPLE_INSTALL_NAME}"
        "LINKER:-compatibility_version,1.0.0" "LINKER:-current_version,1.0.0"
        "LINKER:-dead_strip" "LINKER:-rpath,@loader_path"
    )
    target_link_libraries(partout PRIVATE "-framework CoreFoundation" "-framework Security")
endif()

if(WIN32)
    # Match the DLL architecture to the configured native toolchain.
    target_link_options(partout PRIVATE "LINKER:/MACHINE:${CMAKE_C_COMPILER_ARCHITECTURE_ID}")
    set_target_properties(partout ${partout_runtime_targets} PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL MSVC_RUNTIME_CHECKS "")
    target_compile_definitions(partout INTERFACE PARTOUT_API_USE_DLL)
    set_target_properties(partout PROPERTIES
        PDB_OUTPUT_DIRECTORY "${PP_BUILD_OUTPUT}/partout/bin/$<0:>"
        WINDOWS_EXPORT_ALL_SYMBOLS OFF
    )
    # C++ exports are annotated in the static runtime implementations.
    foreach(symbol IN LISTS partout_exports)
        target_link_options(partout PRIVATE "LINKER:/EXPORT:${symbol}")
    endforeach()
    target_link_libraries(partout PRIVATE msvcrt bcrypt ole32 ws2_32 ntdll)
elseif(NOT APPLE)
    find_package(Threads REQUIRED)
    target_link_libraries(partout PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
    set_target_properties(partout PROPERTIES BUILD_RPATH "$ORIGIN" INSTALL_RPATH "$ORIGIN")
    target_link_options(partout PRIVATE "LINKER:-z,defs")
    # Android exports only the Zig C ABI and JNI entry points.
    if(ANDROID)
        target_link_libraries(partout PRIVATE android)
        list(APPEND partout_exports JNI_OnLoad "Java_io_partout_PartoutWrapper_*")
        list(JOIN partout_exports "; " partout_elf_exports)
        file(CONFIGURE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/partout.map"
            CONTENT "{ global: @partout_elf_exports@; local: *; };\n" @ONLY
        )
        target_link_options(partout PRIVATE
            "LINKER:--version-script,${CMAKE_CURRENT_BINARY_DIR}/partout.map"
        )
        set_property(TARGET partout APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/partout.map")
    endif()
endif()
