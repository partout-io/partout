# SPDX-License-Identifier: MIT
#
# Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.

# First target is default target
all: clean build install

# Go configuration
GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)
HOST_GOROOT := $(shell go env GOROOT)
export GOOS
export GOARCH

BUILDMODE ?= c-shared
ifeq ($(APPLE),1)
override BUILDMODE := c-archive
endif

# Cross-build for Android
ifeq ($(ANDROID),1)
GOOS := android
GOARCH := arm64
endif

ifeq ($(BUILDMODE),c-archive)
BUILDEXT := a
else ifeq ($(GOOS),linux)
BUILDEXT := so
else ifeq ($(GOOS),android)
BUILDEXT := so
else ifeq ($(GOOS),windows)
BUILDEXT := dll
else # Apple
BUILDEXT := dylib
endif

GO_LDFLAGS := -w
ifneq ($(filter android linux,$(GOOS)),)
GO_LDFLAGS += -extldflags=-Wl,-soname,libwg-go.so
endif

# Build output
MODROOT=src
BUILDDIR ?= $(CURDIR)/build
TMPROOTDIR ?= $(CURDIR)/.goroot
DESTDIR ?= $(CURDIR)/bin/$(GOOS)-$(GOARCH)

# Some specifics on Apple platforms
ifeq ($(APPLE),1)
# Include sysroot
SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path)
TARGET ?= $(GOARCH)-apple-macos
export CGO_CFLAGS := -isysroot $(SDKROOT) -target $(TARGET)
export CGO_CXXFLAGS := $(CGO_CFLAGS)
export CGO_LDFLAGS := -isysroot $(SDKROOT) -target $(TARGET)
export PATH := $(PATH):/opt/homebrew/bin:/usr/local/bin
# Patch runtime
export GOROOT := $(TMPROOTDIR)
$(GOROOT)/.prepared:
	[ -n "$(HOST_GOROOT)" ]
	mkdir -p "$(GOROOT)"
	rsync -a --delete --exclude=pkg/obj/go-build "$(HOST_GOROOT)/" "$(GOROOT)/"
	cat goruntime-*.diff | patch -p1 -f -N -r- -d "$(GOROOT)"
	touch "$@"
else
$(GOROOT)/.prepared:
endif

# Targets

build: $(BUILDDIR)/libwg-go
version-header: $(BUILDDIR)/wireguard-go-version.h

$(BUILDDIR)/libwg-go: export CGO_ENABLED := 1
$(BUILDDIR)/libwg-go: $(GOROOT)/.prepared go.mod
	go build -C $(MODROOT) -ldflags="$(GO_LDFLAGS)" -trimpath -v \
		-o "$(BUILDDIR)/libwg-go.$(BUILDEXT)" \
		-buildmode=$(BUILDMODE)
	rm -f "$(BUILDDIR)/libwg-go.h"

$(DESTDIR)/wireguard-go-version.h: go.mod $(GOROOT)/.prepared
	sed -E -n 's/.*golang\.zx2c4\.com\/wireguard +v[0-9.]+-[0-9]+-([0-9a-f]{8})[0-9a-f]{4}.*/#define WIREGUARD_GO_VERSION "\1"/p' "$<" > "$@"

clean:
	rm -rf "$(BUILDDIR)" "$(DESTDIR)" "$(TMPROOTDIR)"

install: build
	mkdir -p "$(DESTDIR)/lib"
	cp $(BUILDDIR)/libwg-go.* "$(DESTDIR)/lib"
	cp -pR "include" "$(DESTDIR)"

.PHONY: clean build version-header install
