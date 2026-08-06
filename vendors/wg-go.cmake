set(PARTOUT_WGGO_DEPENDENCY "")
set(WGGO_DIR "${PP_BUILD_OUTPUT}/wg-go")
set(WGGO_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendors/wg-go")

if(PP_USE_PREBUILT_VENDORS)
    partout_use_prebuilt_vendor(wg-go WGGO_DIR)
    return()
endif()

if(WIN32)
    set(WGGO_RUNTIME_LIBRARY "${WGGO_DIR}/lib/wg-go.dll")
    set(WGGO_IMPORT_LIBRARY "${WGGO_DIR}/lib/wg-go${CMAKE_IMPORT_LIBRARY_SUFFIX}")
    set(WGGO_OUTPUTS "${WGGO_RUNTIME_LIBRARY}" "${WGGO_IMPORT_LIBRARY}")

    if(ARCH_NAME MATCHES "^(arm64|aarch64)$")
        set(WGGO_GOARCH arm64)
        set(WGGO_MINGW_TRIPLE aarch64-w64-mingw32)
        set(WGGO_MSVC_MACHINE ARM64)
        set(WGGO_DLLTOOL_MACHINE arm64)
    else()
        set(WGGO_GOARCH amd64)
        set(WGGO_MINGW_TRIPLE x86_64-w64-mingw32)
        set(WGGO_MSVC_MACHINE X64)
        set(WGGO_DLLTOOL_MACHINE i386:x86-64)
    endif()

    find_program(WGGO_CC
        NAMES ${WGGO_MINGW_TRIPLE}-clang
        HINTS "$ENV{LLVM_MINGW_ROOT}/bin"
        REQUIRED
    )
    find_program(WGGO_CXX
        NAMES ${WGGO_MINGW_TRIPLE}-clang++
        HINTS "$ENV{LLVM_MINGW_ROOT}/bin"
        REQUIRED
    )

    set(WGGO_BUILD_COMMANDS
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${WGGO_DIR}/include" "${WGGO_DIR}/lib"
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${WGGO_SOURCE_DIR}/include" "${WGGO_DIR}/include"
        COMMAND "${CMAKE_COMMAND}" -E env
            CGO_ENABLED=1
            GOOS=windows
            "GOARCH=${WGGO_GOARCH}"
            "CC=${WGGO_CC}"
            "CXX=${WGGO_CXX}"
            "CGO_CFLAGS=--target=${WGGO_MINGW_TRIPLE}"
            "CGO_CXXFLAGS=--target=${WGGO_MINGW_TRIPLE}"
            go build -C "${WGGO_SOURCE_DIR}/src" -ldflags=-w -trimpath -v
                -o "${WGGO_RUNTIME_LIBRARY}" -buildmode=c-shared
    )
    if(MSVC)
        list(APPEND WGGO_BUILD_COMMANDS
            COMMAND "${CMAKE_AR}" /nologo "/def:${WGGO_SOURCE_DIR}/exports.def"
                "/machine:${WGGO_MSVC_MACHINE}" "/out:${WGGO_IMPORT_LIBRARY}"
        )
    else()
        find_program(WGGO_DLLTOOL NAMES llvm-dlltool dlltool REQUIRED)
        list(APPEND WGGO_BUILD_COMMANDS
            COMMAND "${WGGO_DLLTOOL}" -m "${WGGO_DLLTOOL_MACHINE}"
                -d "${WGGO_SOURCE_DIR}/exports.def" -l "${WGGO_IMPORT_LIBRARY}"
        )
    endif()
else()
    set(WGGO_RUNTIME_LIBRARY
        "${WGGO_DIR}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}wg-go${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(WGGO_OUTPUTS "${WGGO_RUNTIME_LIBRARY}")
    set(WGGO_BUILD_COMMANDS
        COMMAND ${VENDOR_ENV} make -C "${WGGO_SOURCE_DIR}" install "DESTDIR=${WGGO_DIR}"
    )
    if(ANDROID)
        list(APPEND WGGO_BUILD_COMMANDS
            ANDROID=1
            "CC=${CMAKE_LIBRARY_ARCHITECTURE}${ANDROID_NATIVE_API_LEVEL}-clang"
        )
    elseif(APPLE)
        list(APPEND WGGO_BUILD_COMMANDS
            COMMAND install_name_tool -id @rpath/libwg-go.dylib "${WGGO_RUNTIME_LIBRARY}"
        )
    endif()
endif()

file(GLOB_RECURSE WGGO_SOURCES CONFIGURE_DEPENDS
    "${WGGO_SOURCE_DIR}/src/*.go"
    "${WGGO_SOURCE_DIR}/include/*"
)
file(GLOB WGGO_PATCHES CONFIGURE_DEPENDS "${WGGO_SOURCE_DIR}/goruntime-*.diff")
list(APPEND WGGO_SOURCES
    ${WGGO_PATCHES}
    "${WGGO_SOURCE_DIR}/go.mod"
    "${WGGO_SOURCE_DIR}/go.sum"
    "${WGGO_SOURCE_DIR}/Makefile"
)
if(WIN32)
    list(APPEND WGGO_SOURCES "${WGGO_SOURCE_DIR}/exports.def")
endif()

set(WGGO_STAMP "${CMAKE_CURRENT_BINARY_DIR}/vendors/wg-go.stamp")
add_custom_command(
    OUTPUT ${WGGO_OUTPUTS} "${WGGO_STAMP}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/vendors"
    ${WGGO_BUILD_COMMANDS}
    COMMAND "${CMAKE_COMMAND}" -E touch "${WGGO_STAMP}"
    DEPENDS ${WGGO_SOURCES}
    USES_TERMINAL
    COMMAND_EXPAND_LISTS
    VERBATIM
)
add_custom_target(WireGuardGoProject DEPENDS ${WGGO_OUTPUTS} "${WGGO_STAMP}")
set(PARTOUT_WGGO_DEPENDENCY WireGuardGoProject)
