set(WGGO_DIR ${PP_BUILD_OUTPUT}/wg-go)
set(WGGO_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go)

if(WIN32)
    set(WGGO_RUNTIME_LIBRARY ${WGGO_DIR}/lib/wg-go.dll)
    set(WGGO_IMPORT_LIBRARY ${WGGO_DIR}/lib/wg-go${CMAKE_IMPORT_LIBRARY_SUFFIX})
    set(WGGO_BUILD_BYPRODUCTS ${WGGO_RUNTIME_LIBRARY} ${WGGO_IMPORT_LIBRARY})
    set(WGGO_DEF_FILE ${CMAKE_CURRENT_BINARY_DIR}/vendors/wg-go.def)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|aarch64)$")
        set(WGGO_GOARCH arm64)
        set(WGGO_TARGET aarch64-windows-gnu)
        set(WGGO_MSVC_MACHINE ARM64)
        set(WGGO_DLLTOOL_MACHINE arm64)
    else()
        set(WGGO_GOARCH amd64)
        set(WGGO_TARGET x86_64-windows-gnu)
        set(WGGO_MSVC_MACHINE X64)
        set(WGGO_DLLTOOL_MACHINE i386:x86-64)
    endif()
    file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/vendors)
    configure_file(${WGGO_SOURCE_DIR}/exports.def ${WGGO_DEF_FILE} COPYONLY)
    set(WGGO_CMD
        ${CMAKE_COMMAND} -E make_directory ${WGGO_DIR}/include ${WGGO_DIR}/lib
        COMMAND ${CMAKE_COMMAND} -E copy_directory ${WGGO_SOURCE_DIR}/include ${WGGO_DIR}/include
        COMMAND ${CMAKE_COMMAND} -E env
            CGO_ENABLED=1
            GOOS=windows
            GOARCH=${WGGO_GOARCH}
            CGO_CFLAGS=--target=${WGGO_TARGET}
            CGO_CXXFLAGS=--target=${WGGO_TARGET}
            go build -C ${WGGO_SOURCE_DIR}/src -ldflags=-w -trimpath -v -o ${WGGO_RUNTIME_LIBRARY} -buildmode=c-shared
    )
    if(MSVC)
        list(APPEND WGGO_CMD
            COMMAND ${CMAKE_AR} /nologo /def:${WGGO_DEF_FILE} /machine:${WGGO_MSVC_MACHINE} /out:${WGGO_IMPORT_LIBRARY}
        )
    else()
        find_program(WGGO_DLLTOOL_EXECUTABLE NAMES llvm-dlltool dlltool REQUIRED)
        list(APPEND WGGO_CMD
            COMMAND ${WGGO_DLLTOOL_EXECUTABLE} -m ${WGGO_DLLTOOL_MACHINE} -d ${WGGO_DEF_FILE} -l ${WGGO_IMPORT_LIBRARY}
        )
    endif()
else()
    set(WGGO_RUNTIME_LIBRARY ${WGGO_DIR}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}wg-go${CMAKE_SHARED_LIBRARY_SUFFIX})
    set(WGGO_BUILD_BYPRODUCTS ${WGGO_RUNTIME_LIBRARY})
    set(WGGO_CMD
        ${VENDOR_ENV} make -C ${WGGO_SOURCE_DIR}
        DESTDIR=${WGGO_DIR}
    )
    if(ANDROID)
        set(CLANG ${SWIFT_ANDROID_ARCH}-linux-android${ANDROID_NATIVE_API_LEVEL}-clang)
        set(WGGO_CMD ${WGGO_CMD} ANDROID=1 CC=${CLANG})
    endif()
endif()

if(PP_USE_PREBUILT_VENDORS)
    partout_fetch_prebuilt_vendor(wg-go WGGO_DIR)
else()
    if(APPLE)
        set(WGGO_INSTALL_COMMAND
            INSTALL_COMMAND
            install_name_tool -id "@rpath/libwg-go.dylib" "${WGGO_RUNTIME_LIBRARY}"
        )
    else()
        set(WGGO_INSTALL_COMMAND
            INSTALL_COMMAND ""
        )
    endif()

    ExternalProject_Add(WireGuardGoProject
        SOURCE_DIR ${WGGO_SOURCE_DIR}
        CONFIGURE_COMMAND ""
        BUILD_COMMAND ${WGGO_CMD}
        ${WGGO_INSTALL_COMMAND}
        BUILD_IN_SOURCE 1
        BUILD_BYPRODUCTS ${WGGO_BUILD_BYPRODUCTS}
    )
endif()

add_library(WireGuardGo::wg-go SHARED IMPORTED GLOBAL)
set_target_properties(WireGuardGo::wg-go PROPERTIES
    IMPORTED_LOCATION ${WGGO_RUNTIME_LIBRARY}
)
if(UNIX AND NOT APPLE)
    set_target_properties(WireGuardGo::wg-go PROPERTIES
        IMPORTED_NO_SONAME TRUE
    )
endif()
if(WIN32)
    set_target_properties(WireGuardGo::wg-go PROPERTIES
        IMPORTED_IMPLIB ${WGGO_IMPORT_LIBRARY}
    )
endif()

add_library(WireGuardGoInterface INTERFACE)
target_include_directories(WireGuardGoInterface INTERFACE ${WGGO_DIR}/include)
target_link_libraries(WireGuardGoInterface INTERFACE WireGuardGo::wg-go)
if(NOT PP_USE_PREBUILT_VENDORS)
    add_dependencies(WireGuardGo::wg-go WireGuardGoProject)
    add_dependencies(WireGuardGoInterface WireGuardGoProject)
endif()
