// Host-only declaration. This test does not bind sockets to Android networks.
#pragma once
#include <stdint.h>
int android_setsocknetwork(uint64_t network, int fd);
