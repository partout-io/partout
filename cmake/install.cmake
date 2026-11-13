include(GNUInstallDirs)

if(WIN32)
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_BINDIR}")
else()
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
if(TARGET partout-windows-backend)
    set_target_properties(partout-windows-backend PROPERTIES EXPORT_NAME WindowsBackend)
    install(TARGETS partout-windows-backend EXPORT PartoutTargets
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
    if(PP_BUILD_LIBRARY)
        install(FILES "$<TARGET_PDB_FILE:partout-windows-backend>"
            DESTINATION "${CMAKE_INSTALL_BINDIR}"
            CONFIGURATIONS Debug RelWithDebInfo OPTIONAL)
    endif()
endif()
if(TARGET partout-bindings)
    set_target_properties(partout-bindings PROPERTIES EXPORT_NAME WindowsRuntime)
    install(TARGETS partout-bindings EXPORT PartoutTargets ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/include/partout_windows.h"
        DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
    )
endif()

if(PP_BUILD_LIBRARY)
    set_target_properties(partout PROPERTIES EXPORT_NAME Partout)
    install(TARGETS partout EXPORT PartoutTargets
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    )
endif()
if(PARTOUT_RUNTIME_LIBRARIES)
    install(IMPORTED_RUNTIME_ARTIFACTS ${PARTOUT_RUNTIME_LIBRARIES}
        LIBRARY DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        RUNTIME DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
    )
endif()

if(WIN32 AND PP_BUILD_LIBRARY)
    # MSVC writes the PDB beside the final DLL.
    install(FILES "$<TARGET_PDB_FILE:partout>"
        DESTINATION "${PARTOUT_RUNTIME_INSTALL_DESTINATION}"
        CONFIGURATIONS Debug RelWithDebInfo
        OPTIONAL
    )
endif()

if(TARGET partout-posix-runtime)
    set_target_properties(partout-posix-runtime PROPERTIES EXPORT_NAME PosixRuntime)
    install(TARGETS partout-posix-runtime EXPORT PartoutTargets ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    install(FILES cross/posix/include/partout_posix.h DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
endif()

if(TARGET partout-models-impl)
    if(NOT TARGET partout-models-interface)
        install(TARGETS partout-models-impl EXPORT PartoutTargets ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    endif()
    install(DIRECTORY "${PARTOUT_MODELS_INCLUDE}/partout" DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
        FILES_MATCHING PATTERN "*.h")
endif()

set_target_properties(partout-headers PROPERTIES EXPORT_NAME Headers)
install(TARGETS partout-headers EXPORT PartoutTargets)
set(PARTOUT_PACKAGE_MODELS OFF)
if(TARGET partout-models-interface)
    set_target_properties(partout-models-interface PROPERTIES EXPORT_NAME Models)
    install(TARGETS partout-models-interface EXPORT PartoutTargets)
    set(PARTOUT_PACKAGE_MODELS ON)
elseif(TARGET partout-models-impl)
    set_target_properties(partout-models-impl PROPERTIES EXPORT_NAME Models)
    set(PARTOUT_PACKAGE_MODELS ON)
endif()

include(CMakePackageConfigHelpers)
set(partout_package_dir "${CMAKE_INSTALL_LIBDIR}/cmake/partout")
configure_package_config_file("${CMAKE_CURRENT_LIST_DIR}/PartoutConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
    INSTALL_DESTINATION "${partout_package_dir}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/PartoutConfig.cmake"
    DESTINATION "${partout_package_dir}")
install(EXPORT PartoutTargets NAMESPACE Partout::
    DESTINATION "${partout_package_dir}")
