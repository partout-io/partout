#include <stdio.h>
#include "portable/lib.h"
#include "wireguard/wireguard.h"

// FIXME: #199, Rename to wg_go.h in wg-go-apple Swift package
#ifdef __APPLE__
#include "wireguard.h"
#endif

/* The WireGuard API is declared as function pointers, so that
 * we can assign them dynamically based on how the underlying
 * library is linked. */

const char *(*pp_wg_version)();
void (*pp_wg_set_logger)(void *context, pp_wg_logger_fn logger_fn);
#ifdef _WIN32
int (*pp_wg_turn_on)(const char *settings, const char *ifname);
#else
int (*pp_wg_turn_on)(const char *settings, int32_t tun_fd);
#endif
void (*pp_wg_turn_off)(int handle);
int64_t (*pp_wg_set_config)(int handle, const char *settings);
char *(*pp_wg_get_config)(int handle);
void (*pp_wg_bump_sockets)(int handle);
void (*pp_wg_tweak_mobile_roaming)(int handle);
#ifdef __ANDROID_API__
int (*pp_wg_get_socket_v4)(int handle);
int (*pp_wg_get_socket_v6)(int handle);
#endif

#ifdef __APPLE__
/* The Apple library is statically linked as a Swift package.
 * The functions are direct pointers to the embedded symbols.
 */
int load_symbols() {
    pp_wg_version = wgVersion;
    pp_wg_set_logger = wgSetLogger;
    pp_wg_turn_on = wgTurnOn;
    pp_wg_turn_off = wgTurnOff;
    pp_wg_set_config = wgSetConfig;
    pp_wg_get_config = wgGetConfig;
    pp_wg_bump_sockets = wgBumpSockets;
    pp_wg_tweak_mobile_roaming = wgDisableSomeRoamingForBrokenMobileSemantics;
    return 0;
}
#else
/* Other platforms are dynamically linked (dll/dylib/so). Here
 * we set the function pointers to the loaded library symbols.
 */
static pp_lib wg = NULL;

#define LOAD_OR_FAIL(lib, fn, symbol) \
    fn = pp_lib_load(lib, symbol); \
    if (!fn) return -1;

int load_symbols() {
    if (!wg) {
        wg = pp_lib_create("wg-go");
        if (!wg) {
            return -1;
        }
        LOAD_OR_FAIL(wg, pp_wg_version, "wgVersion");
        LOAD_OR_FAIL(wg, pp_wg_set_logger, "wgSetLogger");
        LOAD_OR_FAIL(wg, pp_wg_turn_on, "wgTurnOn");
        LOAD_OR_FAIL(wg, pp_wg_turn_off, "wgTurnOff");
        LOAD_OR_FAIL(wg, pp_wg_set_config, "wgSetConfig");
        LOAD_OR_FAIL(wg, pp_wg_get_config, "wgGetConfig");
        LOAD_OR_FAIL(wg, pp_wg_bump_sockets, "wgBumpSockets");
        LOAD_OR_FAIL(wg, pp_wg_tweak_mobile_roaming, "wgDisableSomeRoamingForBrokenMobileSemantics");
#ifdef __ANDROID_API__
        LOAD_OR_FAIL(wg, pp_wg_get_socket_v4, "wgGetSocketV4");
        LOAD_OR_FAIL(wg, pp_wg_get_socket_v6, "wgGetSocketV6");
#endif
    }
    return 0;
}
#endif

int pp_wg_init() {
    if (load_symbols() != 0) return -1;
    // FIXME: #199, fprintf
    fprintf(stderr, "wg-go version: %s\n", pp_wg_version());
    return 0;
}
