# The Go bridge and its C ABI are developed together with Partout.
find_program(PARTOUT_GO_EXECUTABLE go REQUIRED)
set(PARTOUT_WGGO_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/src/wireguard/go")
set(PARTOUT_WGGO_INCLUDE_DIR "${PARTOUT_WGGO_SOURCE}/include")
set(PARTOUT_WGGO_LIBRARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/wg-go/lib")
file(MAKE_DIRECTORY "${PARTOUT_WGGO_LIBRARY_DIR}")

if(ARCH_NAME MATCHES "^(arm64|aarch64)$")
    set(wg_arch arm64)
    set(wg_mingw aarch64)
    set(wg_machine arm64)
elseif(ARCH_NAME MATCHES "^(x64|x86_64|amd64)$")
    set(wg_arch amd64)
    set(wg_mingw x86_64)
    set(wg_machine i386:x86-64)
else()
    message(FATAL_ERROR "Unsupported wg-go architecture: ${ARCH_NAME}")
endif()

if(APPLE)
    find_program(PARTOUT_MAKE_EXECUTABLE make REQUIRED)
    execute_process(COMMAND "${PARTOUT_GO_EXECUTABLE}" version
        OUTPUT_VARIABLE wg_go_version COMMAND_ERROR_IS_FATAL ANY)
    execute_process(COMMAND "${PARTOUT_GO_EXECUTABLE}" env GOROOT
        OUTPUT_VARIABLE wg_goroot COMMAND_ERROR_IS_FATAL ANY)
    file(SHA256 "${PARTOUT_WGGO_SOURCE}/goruntime-boottime-over-monotonic.diff" wg_patch_hash)
    string(SHA256 wg_runtime_key "${wg_go_version}${wg_goroot}${wg_patch_hash}")
    set(wg_library "${PARTOUT_WGGO_LIBRARY_DIR}/libwg-go.a")
    if(wg_arch STREQUAL "amd64")
        set(wg_apple_arch x86_64)
    else()
        set(wg_apple_arch arm64)
    endif()
    set(wg_target "${wg_apple_arch}-apple-macos")
    if(CMAKE_OSX_DEPLOYMENT_TARGET)
        string(APPEND wg_target "${CMAKE_OSX_DEPLOYMENT_TARGET}")
    endif()
    add_custom_target(partout_wg_go_build
        COMMAND "${PARTOUT_MAKE_EXECUTABLE}" -C "${PARTOUT_WGGO_SOURCE}" install
            APPLE=1 GOOS=darwin "GOARCH=${wg_arch}" "TARGET=${wg_target}"
            "BUILDDIR=${CMAKE_CURRENT_BINARY_DIR}/wg-go/build"
            "DESTDIR=${CMAKE_CURRENT_BINARY_DIR}/wg-go"
            "TMPROOTDIR=${CMAKE_CURRENT_BINARY_DIR}/wg-go/goroot-${wg_runtime_key}"
        BYPRODUCTS "${wg_library}" VERBATIM USES_TERMINAL)
else()
    set(wg_env CGO_ENABLED=1 "GOARCH=${wg_arch}" "CC=${CMAKE_C_COMPILER}")
    set(wg_flags "${CMAKE_C_FLAGS}")
    if(CMAKE_C_COMPILER_TARGET)
        string(APPEND wg_flags " --target=${CMAKE_C_COMPILER_TARGET}")
    endif()
    if(CMAKE_SYSROOT)
        string(APPEND wg_flags " --sysroot=${CMAKE_SYSROOT}")
    endif()
    list(APPEND wg_env "CGO_CFLAGS=${wg_flags}" "CGO_LDFLAGS=${wg_flags}")
    set(wg_ldflags "-w -extldflags=-Wl,-soname,libwg-go.so")
    set(wg_library "${PARTOUT_WGGO_LIBRARY_DIR}/libwg-go.so")
    if(WIN32)
        find_program(PARTOUT_WGGO_CC "${wg_mingw}-w64-mingw32-clang"
            HINTS "$ENV{LLVM_MINGW_ROOT}/bin" REQUIRED)
        find_program(PARTOUT_WGGO_DLLTOOL llvm-dlltool
            HINTS "$ENV{LLVM_MINGW_ROOT}/bin" REQUIRED)
        set(wg_env CGO_ENABLED=1 GOOS=windows "GOARCH=${wg_arch}" "CC=${PARTOUT_WGGO_CC}")
        set(wg_ldflags -w)
        set(wg_library "${PARTOUT_WGGO_LIBRARY_DIR}/wg-go.dll")
        set(wg_implib "${PARTOUT_WGGO_LIBRARY_DIR}/wg-go.lib")
        set(wg_import_command COMMAND "${PARTOUT_WGGO_DLLTOOL}"
            -m "${wg_machine}" -d "${PARTOUT_WGGO_SOURCE}/exports.def" -l "${wg_implib}")
    elseif(ANDROID)
        list(APPEND wg_env GOOS=android)
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        list(APPEND wg_env GOOS=linux)
    else()
        message(FATAL_ERROR "Unsupported wg-go platform: ${CMAKE_SYSTEM_NAME}")
    endif()
    # Always invoke Go: its own cache tracks all sources, headers and dependencies.
    add_custom_target(partout_wg_go_build
        COMMAND "${CMAKE_COMMAND}" -E env ${wg_env}
            "${PARTOUT_GO_EXECUTABLE}" build -C "${PARTOUT_WGGO_SOURCE}/src"
            "-ldflags=${wg_ldflags}" -trimpath -buildmode=c-shared -o "${wg_library}"
        ${wg_import_command}
        BYPRODUCTS "${wg_library}" ${wg_implib}
        VERBATIM USES_TERMINAL)
    add_library(partout_wg_go SHARED IMPORTED GLOBAL)
    set_target_properties(partout_wg_go PROPERTIES IMPORTED_LOCATION "${wg_library}")
    if(WIN32)
        set_property(TARGET partout_wg_go PROPERTY IMPORTED_IMPLIB "${wg_implib}")
    endif()
    add_dependencies(partout_wg_go partout_wg_go_build)
    list(APPEND PARTOUT_RUNTIME_LIBRARIES partout_wg_go)
endif()
