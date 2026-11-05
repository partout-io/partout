# WinRT uses MSVC's C++ runtime and Windows SDK projections. Build this bridge
# separately from Zig's portable C sources; consumers opt in when needed.
option(PP_BUILD_WINRT "Build the WinRT VPN channel bridge" OFF)
if(NOT PP_BUILD_WINRT)
    return()
endif()

if(CMAKE_VERSION VERSION_LESS 4.0)
    message(FATAL_ERROR "PP_BUILD_WINRT requires CMake 4.0 or newer")
endif()
if(NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "PP_BUILD_WINRT requires MSVC and the Windows SDK")
endif()

include(FetchContent)
enable_language(CXX)
FetchContent_Declare(json
    URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
    URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
)
FetchContent_MakeAvailable(json)

# The native backend cannot include Partout headers. Keep it independently
# compilable; runtime.cc and platform.cc integrate with Partout's APIs.
add_library(partout-windows-backend SHARED
    cross/windows/src/abi.cc
    cross/windows/src/loop.cc
    cross/windows/src/network.cc
    cross/windows/src/socket.cc
    cross/windows/src/tun.cc
    cross/windows/src/tun_settings.cc
    cross/windows/src/log.cc
)
target_include_directories(partout-windows-backend PUBLIC cross/windows/include)
target_link_libraries(partout-windows-backend PUBLIC windowsapp runtimeobject ws2_32 iphlpapi
    PRIVATE nlohmann_json::nlohmann_json)

# Runtime integration is linked by consumers; the core links only the backend.
add_library(partout-windows STATIC cross/windows/src/runtime.cc cross/windows/src/platform.cc)
file(GLOB partout_model_sources CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/src/models/*.cpp")
# Generated model implementations do not follow our warning policy.
add_library(partout-windows-models OBJECT ${partout_model_sources})
target_compile_options(partout-windows-models PRIVATE /w)
target_link_libraries(partout-windows-models PRIVATE nlohmann_json::nlohmann_json)
target_link_libraries(partout-windows-backend PRIVATE partout-windows-models)
set_target_properties(partout-windows-backend PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
target_include_directories(partout-windows PUBLIC cross/windows/include PRIVATE src)
target_compile_features(partout-windows PUBLIC cxx_std_20)
target_link_libraries(partout-windows PUBLIC partout-windows-backend PRIVATE nlohmann_json::nlohmann_json)
add_library(Partout::WindowsRuntime ALIAS partout-windows)

foreach(target IN ITEMS partout-windows-backend partout-windows partout-windows-models)
    # Also suppress model header warnings in handwritten translation units.
    target_include_directories(${target} SYSTEM PRIVATE cross/windows/src/models)
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_compile_definitions(${target} PRIVATE NOMINMAX WINRT_LEAN_AND_MEAN)
    target_compile_options(${target} PRIVATE /EHsc /permissive-)
    if(NOT target STREQUAL "partout-windows-models")
        target_compile_options(${target} PRIVATE /W4)
    endif()
    # AppContainer consumers use a CRT without the /RTC helpers.
    set_target_properties(${target} PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
    )
endforeach()
