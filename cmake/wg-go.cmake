# CMake builds the Go bridge; Zig consumes its C ABI and library.
find_program(PARTOUT_GO_EXECUTABLE go REQUIRED)
set(wg_source "${CMAKE_CURRENT_SOURCE_DIR}/src/wireguard/go")
set(wg_output "${PP_BUILD_OUTPUT}/partout")
set(wg_work "${CMAKE_CURRENT_BINARY_DIR}/wg-go")
file(MAKE_DIRECTORY "${wg_work}/lib")

set(wg_target_arch "${ARCH_NAME}")
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
    set(wg_target_arch "${CMAKE_OSX_ARCHITECTURES}")
endif()
if(wg_target_arch MATCHES "^(arm64|aarch64)$")
    set(wg_arch arm64)
    set(wg_zig_arch aarch64)
    set(wg_machine arm64)
elseif(wg_target_arch MATCHES "^(x64|x86_64|amd64)$")
    set(wg_arch amd64)
    set(wg_zig_arch x86_64)
    set(wg_machine i386:x86-64)
else()
    message(FATAL_ERROR "Unsupported WireGuard architecture: ${wg_target_arch}")
endif()
execute_process(COMMAND "${PARTOUT_GO_EXECUTABLE}" -C "${wg_source}" env -json
        GOROOT GOVERSION GOFLAGS GOEXPERIMENT GOTOOLCHAIN GOAMD64 GOARM64 GOWORK
        CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS
    OUTPUT_VARIABLE wg_toolchain COMMAND_ERROR_IS_FATAL ANY)
string(JSON wg_goroot GET "${wg_toolchain}" GOROOT)
# Module/toolchain changes must also refresh the selected GOROOT and patch key.
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${wg_source}/go.mod" "${wg_source}/go.sum" "${wg_goroot}/VERSION"
    "${PARTOUT_GO_EXECUTABLE}" "${wg_source}/goruntime-boottime-over-monotonic.diff")
set(wg_env CGO_ENABLED=1 "GOARCH=${wg_arch}")
set(wg_flags "${CMAKE_C_FLAGS}")
set(wg_mode c-shared)
set(wg_library "${wg_work}/lib/libwg-go.so")
set(wg_ldflags "-w -extldflags=-Wl,-soname,libwg-go.so")
set(wg_inputs "${PARTOUT_GO_EXECUTABLE}" "${wg_goroot}/VERSION")

if(WIN32)
    find_program(PARTOUT_ZIG_EXECUTABLE zig REQUIRED)
    set(wg_flags "")
    set(wg_cc "\"${PARTOUT_ZIG_EXECUTABLE}\" cc -fno-sanitize=undefined -target ${wg_zig_arch}-windows-gnu")
    set(wg_os windows)
    set(wg_ldflags -w)
    set(wg_library "${wg_work}/lib/wg-go.dll")
    set(wg_implib "${wg_work}/lib/wg-go.lib")
    set(wg_import_command COMMAND "${PARTOUT_ZIG_EXECUTABLE}" dlltool
        -m "${wg_machine}" -d "${wg_source}/exports.def" -l "${wg_implib}")
    list(APPEND wg_inputs "${PARTOUT_ZIG_EXECUTABLE}" "${wg_source}/exports.def")
else()
    set(wg_cc "\"${CMAKE_C_COMPILER}\"")
    list(APPEND wg_inputs "${CMAKE_C_COMPILER}")
    if(APPLE)
        set(wg_os darwin)
        if(IS_DIRECTORY "${CMAKE_OSX_SYSROOT}")
            set(wg_sdk "${CMAKE_OSX_SYSROOT}")
        else()
            execute_process(COMMAND xcrun --sdk macosx --show-sdk-path
                OUTPUT_VARIABLE wg_sdk OUTPUT_STRIP_TRAILING_WHITESPACE
                COMMAND_ERROR_IS_FATAL ANY)
        endif()
        if(wg_arch STREQUAL "arm64")
            set(wg_apple_arch arm64)
        else()
            set(wg_apple_arch x86_64)
        endif()
        if(CMAKE_C_COMPILER_TARGET)
            set(wg_target "${CMAKE_C_COMPILER_TARGET}")
        else()
            set(wg_target "${wg_apple_arch}-apple-macos${CMAKE_OSX_DEPLOYMENT_TARGET}")
        endif()
        if(wg_target MATCHES "-apple-(ios|tvos)")
            set(wg_os ios)
        endif()
        set(wg_mode c-archive)
        set(wg_library "${wg_work}/lib/libwg-go.a")
        set(wg_ldflags -w)
        string(APPEND wg_flags " -isysroot \"${wg_sdk}\" -target ${wg_target}")
        list(APPEND wg_inputs "${wg_sdk}/SDKSettings.json")

        set(PP_BUILD_GO_RUNTIME_CACHE "${CMAKE_CURRENT_BINARY_DIR}/go-runtime" CACHE PATH
            "Cache for the patched Apple Go runtime, shareable across slices")
        set(wg_patch "${wg_source}/goruntime-boottime-over-monotonic.diff")
        file(SHA256 "${wg_patch}" wg_patch_hash)
        string(JSON wg_version GET "${wg_toolchain}" GOVERSION)
        string(SHA256 wg_runtime_key "${wg_goroot};${wg_version};${wg_patch_hash}")
        set(wg_runtime "${PP_BUILD_GO_RUNTIME_CACHE}/${wg_runtime_key}")
        find_program(PARTOUT_RSYNC_EXECUTABLE rsync REQUIRED)
        find_program(PARTOUT_PATCH_EXECUTABLE patch REQUIRED)
        add_custom_command(OUTPUT "${wg_runtime}/.prepared"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${wg_runtime}"
            COMMAND "${PARTOUT_RSYNC_EXECUTABLE}" -a --exclude=pkg/obj/go-build "${wg_goroot}/" "${wg_runtime}/"
            COMMAND "${PARTOUT_PATCH_EXECUTABLE}" -p1 -f -N -d "${wg_runtime}" -i "${wg_patch}"
            COMMAND "${CMAKE_COMMAND}" -E touch "${wg_runtime}/.prepared"
            DEPENDS "${wg_patch}" "${wg_goroot}/VERSION"
            COMMENT "Prepare Apple Go runtime" VERBATIM)
        list(APPEND wg_inputs "${wg_runtime}/.prepared")
        list(APPEND wg_env "GOROOT=${wg_runtime}")
    else()
        if(ANDROID)
            set(wg_os android)
        elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
            set(wg_os linux)
        else()
            message(FATAL_ERROR "Unsupported WireGuard platform: ${CMAKE_SYSTEM_NAME}")
        endif()
        if(CMAKE_C_COMPILER_TARGET)
            string(APPEND wg_flags " --target=${CMAKE_C_COMPILER_TARGET}")
        endif()
        if(CMAKE_SYSROOT)
            string(APPEND wg_flags " --sysroot \"${CMAKE_SYSROOT}\"")
        endif()
    endif()
endif()
list(APPEND wg_env "GOOS=${wg_os}" "CC=${wg_cc}")
foreach(key CGO_CFLAGS CGO_CXXFLAGS CGO_LDFLAGS)
    string(JSON value GET "${wg_toolchain}" ${key})
    list(APPEND wg_env "${key}=${value} ${wg_flags}")
endforeach()

# The bridge is flat. Never scan old .goroot/build directories as source input.
file(GLOB wg_sources CONFIGURE_DEPENDS
    "${wg_source}/*.go" "${wg_source}/*.c" "${wg_source}/*.h" "${wg_source}/*.s"
    "${wg_source}/go.*" "${wg_source}/include/wg_go/*.h")
# Reconfiguration updates this file only when settings or the source list change.
# The output rule skips Go entirely on unchanged builds.
file(CONFIGURE OUTPUT "${wg_work}/settings.txt"
    CONTENT "${wg_toolchain}\n${wg_env}\n${wg_mode}\n${wg_ldflags}\n${wg_sources}\n" @ONLY)
add_custom_command(OUTPUT "${wg_library}" ${wg_implib}
    COMMAND "${CMAKE_COMMAND}" -E env ${wg_env}
        "${PARTOUT_GO_EXECUTABLE}" build -C "${wg_source}" -trimpath
        "-ldflags=${wg_ldflags}" "-buildmode=${wg_mode}" -o "${wg_library}"
    ${wg_import_command}
    COMMAND "${CMAKE_COMMAND}" -E touch "${wg_library}" ${wg_implib}
    DEPENDS ${wg_sources} ${wg_inputs} "${wg_work}/settings.txt" "${CMAKE_CURRENT_LIST_FILE}"
    COMMENT "Build WireGuard Go bridge (${wg_os}/${wg_arch})" VERBATIM)
# Keep compilation outputs local to each CMake configuration. Publish runtimes
# beside Partout as well, so the build output can be loaded before installation.
if(NOT APPLE)
    set(wg_runtime_destination "${wg_output}/lib")
    if(WIN32)
        set(wg_runtime_destination "${wg_output}/bin")
        set(wg_copy_implib
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${wg_output}/lib"
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${wg_implib}" "${wg_output}/lib/")
    endif()
    set(wg_copy_runtime
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${wg_runtime_destination}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${wg_library}" "${wg_runtime_destination}/")
endif()
add_custom_target(partout-wg-go DEPENDS "${wg_library}" ${wg_implib}
    ${wg_copy_runtime} ${wg_copy_implib} VERBATIM)
if(APPLE)
    add_library(Partout::WireGuard STATIC IMPORTED GLOBAL)
else()
    add_library(Partout::WireGuard SHARED IMPORTED GLOBAL)
    list(APPEND PARTOUT_RUNTIME_LIBRARIES Partout::WireGuard)
endif()
set_target_properties(Partout::WireGuard PROPERTIES IMPORTED_LOCATION "${wg_library}")
if(WIN32)
    set_property(TARGET Partout::WireGuard PROPERTY IMPORTED_IMPLIB "${wg_implib}")
endif()
add_dependencies(Partout::WireGuard partout-wg-go)
