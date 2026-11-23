// SPDX-FileCopyrightText: 2026 Davide De Rosa
// SPDX-License-Identifier: GPL-3.0
#include "partout_platform.h"
#include <errno.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_OSX
#include <string.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/sys_domain.h>
#include <sys/kern_control.h>
#include <net/if_utun.h>
#elif defined(__linux__) && !defined(__ANDROID__)
#include <fcntl.h>
#include <linux/if_tun.h>
#include <net/if.h>
#include <sys/ioctl.h>
#endif

#define PARTOUT_IO_RETRY(result, operation) \
    do { result = (operation); } while (result < 0 && errno == EINTR)

static partout_tun open_tun(const char *uuid) {
    if (!uuid) return NULL;
#if defined(__APPLE__) && TARGET_OS_OSX
    const int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return NULL;
    struct ctl_info info = { 0 };
    strncpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    int ret;
    PARTOUT_IO_RETRY(ret, ioctl(fd, CTLIOCGINFO, &info));
    if (ret < 0) goto failure;
    struct sockaddr_ctl address = { 0 };
    address.sc_len = sizeof(address);
    address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL;
    address.sc_id = info.ctl_id;
    PARTOUT_IO_RETRY(ret, connect(fd, (struct sockaddr *)&address, sizeof(address)));
    if (ret < 0) goto failure;
#elif defined(__linux__) && !defined(__ANDROID__)
    int fd;
    PARTOUT_IO_RETRY(fd, open("/dev/net/tun", O_RDWR));
    if (fd < 0) return NULL;
    struct ifreq request = { 0 };
    request.ifr_flags = IFF_TUN | IFF_NO_PI;
    int ret;
    PARTOUT_IO_RETRY(ret, ioctl(fd, TUNSETIFF, &request));
    if (ret < 0) goto failure;
#else
    return NULL;
#endif
#if (defined(__APPLE__) && TARGET_OS_OSX) || (defined(__linux__) && !defined(__ANDROID__))
    partout_tun tun = partout_tun_wrap_fd(fd, true);
    if (tun) return tun;
failure:
    close(fd);
    return NULL;
#endif
}

static partout_tun set_tunnel(void *ctx, const char *uuid, const char *json) {
    (void)ctx;
    (void)json;
    return open_tun(uuid);
}

static void set_delegate(void *ctx, const partout_controller_delegate *delegate) {
    (void)ctx;
    (void)delegate;
}

static void report_snapshot(void *ctx, const char *json) {
    (void)ctx;
    (void)json;
}

static void set_environment(void *ctx, const char *key, const char *json) {
    (void)ctx;
    (void)key;
    (void)json;
}

static void clear_tunnel(void *ctx, bool kill_switch) {
    (void)ctx;
    (void)kill_switch;
}

static void cancel_tunnel(void *ctx, const char *code) {
    (void)ctx;
    (void)code;
}

static bool configure_sockets(void *ctx, const partout_reachability *info,
                               const partout_socket_descriptor *fds, size_t count) {
    (void)ctx;
    (void)info;
    (void)fds;
    (void)count;
    return true;
}

static partout_controller_functions controller_functions(void) {
    const partout_controller_functions functions = {
        .set_delegate = set_delegate,
        .set_tunnel = set_tunnel,
        .report_snapshot = report_snapshot,
        .set_environment_value = set_environment,
        .clear_tunnel = clear_tunnel,
        .cancel_tunnel = cancel_tunnel,
        .configure_sockets = configure_sockets
    };
    return functions;
}

bool partout_platform_bindings_init(partout_daemon_bindings *bindings) {
    if (!bindings) return false;
    bindings->controller = NULL;
    bindings->controller_functions = controller_functions();
    bindings->release = NULL;
    return true;
}
