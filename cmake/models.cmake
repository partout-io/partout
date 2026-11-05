# Portable generated models, independent of the Windows bridge.
include_guard(GLOBAL)
if(NOT TARGET nlohmann_json::nlohmann_json)
    include(FetchContent)
    FetchContent_Declare(json
        URL https://github.com/nlohmann/json/releases/download/v3.12.0/json.tar.xz
        URL_HASH SHA256=42f6e95cad6ec532fd372391373363b62a14af6d771056dbfc86160e6dfff7aa
    )
    FetchContent_MakeAvailable(json)
endif()
get_filename_component(PARTOUT_MODELS_ROOT "${CMAKE_CURRENT_LIST_DIR}/../cross/cpp" ABSOLUTE)
set(PARTOUT_MODELS_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/partout-models/include")
set(partout_models_dll OFF)
if(WIN32 AND PP_BUILD_WINDOWS AND PP_BUILD_LIBRARY)
    set(partout_models_dll ON)
endif()
file(GLOB partout_model_headers CONFIGURE_DEPENDS "${PARTOUT_MODELS_ROOT}/models/*.h")
foreach(header IN LISTS partout_model_headers)
    get_filename_component(name "${header}" NAME)
    if(partout_models_dll)
        # Annotate out-of-line methods in the SDK copy, leaving generator output
        # untouched. Do not export implicit constructors or STL/template members.
        set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${header}")
        file(READ "${header}" model_header)
        string(REGEX REPLACE "(\n[ ]*)((bool|void|nlohmann::json|static [A-Za-z0-9_]+) (operator==|operator!=|Validate|ToJson|FromJson|to_json|from_json|validateRfc3339_date|validateRfc3339_date_time)\\([^;\n]*;)"
            "\\1PARTOUT_MODELS_API \\2" model_header "${model_header}")
        string(PREPEND model_header "#include \"../export.h\"\n")
        file(CONFIGURE OUTPUT "${PARTOUT_MODELS_INCLUDE}/partout/models/${name}"
            CONTENT "${model_header}" @ONLY NEWLINE_STYLE LF)
    else()
        configure_file("${header}" "${PARTOUT_MODELS_INCLUDE}/partout/models/${name}" COPYONLY)
    endif()
endforeach()
configure_file("${PARTOUT_MODELS_ROOT}/json.h" "${PARTOUT_MODELS_INCLUDE}/partout/json.h" COPYONLY)

file(GLOB partout_model_sources CONFIGURE_DEPENDS "${PARTOUT_MODELS_ROOT}/models/*.cpp")
if(partout_models_dll)
    file(CONFIGURE OUTPUT "${PARTOUT_MODELS_INCLUDE}/partout/export.h" CONTENT
"#pragma once
#if defined(PARTOUT_MODELS_BUILD_DLL)
#define PARTOUT_MODELS_API __declspec(dllexport)
#else
#define PARTOUT_MODELS_API __declspec(dllimport)
#endif
" @ONLY NEWLINE_STYLE LF)
    set(model_build_sources)
    foreach(source IN LISTS partout_model_sources)
        get_filename_component(name "${source}" NAME)
        set(copy "${PARTOUT_MODELS_INCLUDE}/partout/models/${name}")
        configure_file("${source}" "${copy}" COPYONLY)
        list(APPEND model_build_sources "${copy}")
    endforeach()
    set(partout_model_sources ${model_build_sources})
endif()
add_library(partout-models-impl STATIC ${partout_model_sources})
if(partout_models_dll)
    target_compile_definitions(partout-models-impl PRIVATE PARTOUT_MODELS_BUILD_DLL)
endif()
target_compile_features(partout-models-impl PUBLIC cxx_std_17)
target_compile_definitions(partout-models-impl PUBLIC NOMINMAX)
target_include_directories(partout-models-impl SYSTEM PUBLIC "${PARTOUT_MODELS_INCLUDE}")
target_link_libraries(partout-models-impl PUBLIC nlohmann_json::nlohmann_json)

# Windows SDK consumers use the DLL's model exports. The implementation archive
# is only a build input; linking it into consumers would duplicate those symbols.
if(partout_models_dll)
    add_library(partout-models-interface INTERFACE)
    add_library(Partout::Models ALIAS partout-models-interface)
    target_compile_features(partout-models-interface INTERFACE cxx_std_17)
    target_compile_definitions(partout-models-interface INTERFACE NOMINMAX)
    target_include_directories(partout-models-interface SYSTEM INTERFACE "${PARTOUT_MODELS_INCLUDE}")
    target_link_libraries(partout-models-interface INTERFACE partout-windows-backend nlohmann_json::nlohmann_json)
else()
    add_library(Partout::Models ALIAS partout-models-impl)
endif()
