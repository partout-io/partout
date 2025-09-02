#include <stdio.h>
#include <windows.h>
#include "portable/tun.h"

int main() {
    puts("Hello");
    pp_tun tun = pp_tun_create(NULL);
    Sleep(1000 * 1000); // 1000 seconds
    return 0;
}
