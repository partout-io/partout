ExternalProject_Add(SWONProject
    SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendors/swon
    BINARY_DIR ${CMAKE_CURRENT_BINARY_DIR}/vendors/swon
    INSTALL_COMMAND ""
)

add_library(SWONInterface INTERFACE)
add_dependencies(SWONInterface SWONProject)
target_include_directories(SWONInterface INTERFACE
    ${CMAKE_CURRENT_BINARY_DIR}/vendors/swon
    ${CMAKE_CURRENT_SOURCE_DIR}/vendors/swon/Sources/SWON_C/include
)
target_compile_options(SWONInterface INTERFACE
    -load-plugin-executable "${CMAKE_CURRENT_BINARY_DIR}/vendors/swon/SWONMacros#SWONMacros"
)
target_link_libraries(SWONInterface INTERFACE SWON)
