# Portable models and extensions.
include_guard(GLOBAL)
if(NOT TARGET nlohmann_json::nlohmann_json)
    include(FetchContent)
    FetchContent_Declare(json
        URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
        URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
    )
    # The installed models expose JSON types and require its exported package.
    set(JSON_Install ${partout_install_sdk})
    FetchContent_MakeAvailable(json)
endif()
set(PARTOUT_CPP_ROOT "${CMAKE_CURRENT_LIST_DIR}/../runtimes/cpp")
set(PARTOUT_CPP_INCLUDE "${PARTOUT_CPP_ROOT}/include")
set(partout_models_dll OFF)
if(WIN32 AND PP_BUILD_WINRT AND PP_BUILD_LIBRARY)
    set(partout_models_dll ON)
endif()

file(GLOB model_sources CONFIGURE_DEPENDS "${PARTOUT_CPP_ROOT}/models/*.cc")
add_library(partout-models-impl STATIC ${model_sources}
    "${PARTOUT_CPP_ROOT}/extensions/ModuleExtensions.cc"
    "${PARTOUT_CPP_ROOT}/extensions/ProfileExtensions.cc")
set_target_properties(partout-models-impl PROPERTIES UNITY_BUILD ON)

# WinRT exposes models through its DLL; other platforms link the static archive.
set(model_targets partout-models-impl)
set(model_scopes PUBLIC)
if(partout_models_dll)
    target_compile_definitions(partout-models-impl PRIVATE PARTOUT_API_BUILD_DLL)
    add_library(partout-models-interface INTERFACE)
    add_library(Partout::Models ALIAS partout-models-interface)
    target_compile_definitions(partout-models-interface INTERFACE PARTOUT_API_USE_DLL)
    target_link_libraries(partout-models-interface INTERFACE partout-winrt-backend)
    list(APPEND model_targets partout-models-interface)
    list(APPEND model_scopes INTERFACE)
else()
    add_library(Partout::Models ALIAS partout-models-impl)
endif()
foreach(target scope IN ZIP_LISTS model_targets model_scopes)
    target_compile_features(${target} ${scope} cxx_std_17)
    target_compile_definitions(${target} ${scope} NOMINMAX)
    target_include_directories(${target} SYSTEM ${scope}
        "$<BUILD_INTERFACE:${PARTOUT_CPP_INCLUDE}>"
        "$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>"
    )
    target_link_libraries(${target} ${scope} nlohmann_json::nlohmann_json)
endforeach()
