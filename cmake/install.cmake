include(GNUInstallDirs)

if(WIN32)
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_BINDIR}")
else()
    set(PARTOUT_RUNTIME_INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/src/partout.h"
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
)
if(TARGET partout-windows-backend AND NOT PP_BUILD_LIBRARY)
    install(TARGETS partout-windows-backend ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()
if(TARGET partout-windows)
    install(TARGETS partout-windows ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/cross/windows/include/partout_windows.h"
        DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
    )
endif()

if(PP_BUILD_LIBRARY)
    install(TARGETS partout
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
    install(TARGETS partout-posix-runtime ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    install(FILES cross/posix/include/partout_posix.h DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")
endif()

if(TARGET partout-models-impl)
    if(NOT TARGET partout-models-interface)
        install(TARGETS partout-models-impl ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}")
    endif()
    install(DIRECTORY "${PARTOUT_MODELS_INCLUDE}/partout" DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}"
        FILES_MATCHING PATTERN "*.h")
endif()
