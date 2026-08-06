partout_use_prebuilt_vendor(wintun WINTUN_DIR)
if(NOT EXISTS "${WINTUN_DIR}/wintun.dll" OR NOT EXISTS "${WINTUN_DIR}/wintun.h")
    message(FATAL_ERROR "Prebuilt Wintun is incomplete in ${WINTUN_DIR}")
endif()
