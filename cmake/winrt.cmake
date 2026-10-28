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
FetchContent_Declare(json URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz)
FetchContent_MakeAvailable(json)

# The native backend cannot include Partout headers. Keep it independently
# compilable; runtime.cc and platform.cc integrate with Partout's APIs.
add_library(partout-winrt-backend OBJECT
    cross/windows/src/abi.cc
    cross/windows/src/loop.cc
    cross/windows/src/network.cc
    cross/windows/src/socket.cc
    cross/windows/src/tun.cc
    cross/windows/src/tun_settings.cc
    cross/windows/src/log.cc
)
target_include_directories(partout-winrt-backend PUBLIC cross/windows/include)
target_link_libraries(partout-winrt-backend PUBLIC windowsapp runtimeobject ws2_32 iphlpapi
    PRIVATE nlohmann_json::nlohmann_json)

# Preserve a single archive for Zig and existing consumers.
add_library(partout-winrt STATIC cross/windows/src/runtime.cc cross/windows/src/platform.cc)
file(GLOB partout_model_sources CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/src/models/*.cpp")
# Generated model implementations do not follow our warning policy.
add_library(partout-winrt-models OBJECT ${partout_model_sources})
target_compile_options(partout-winrt-models PRIVATE /w)
target_link_libraries(partout-winrt-models PRIVATE nlohmann_json::nlohmann_json)
target_include_directories(partout-winrt PRIVATE src src/c/portable/include)
target_compile_definitions(partout-winrt PRIVATE PARTOUT_WINRT_EXPORTS)
target_link_libraries(partout-winrt PRIVATE partout-winrt-backend partout-winrt-models nlohmann_json::nlohmann_json)

foreach(target IN ITEMS partout-winrt-backend partout-winrt partout-winrt-models)
    # Also suppress model header warnings in handwritten translation units.
    target_include_directories(${target} SYSTEM PRIVATE cross/windows/src/models)
    target_compile_features(${target} PRIVATE cxx_std_20)
    target_compile_definitions(${target} PRIVATE NOMINMAX WINRT_LEAN_AND_MEAN)
    target_compile_options(${target} PRIVATE /EHsc /permissive-)
    if(NOT target STREQUAL "partout-winrt-models")
        target_compile_options(${target} PRIVATE /W4)
    endif()
    # AppContainer consumers use a CRT without the /RTC helpers.
    set_target_properties(${target} PROPERTIES
        MSVC_RUNTIME_LIBRARY MultiThreadedDLL
        MSVC_RUNTIME_CHECKS ""
    )
endforeach()
