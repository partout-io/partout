# SPDX-License-Identifier: MIT
#
# Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.

# First target is default target
all: clean build install

# Go configuration
HOST_GOOS := $(shell go env GOOS)
HOST_GOARCH := $(shell go env GOARCH)
HOST_GOROOT := $(shell go env GOROOT)

# Cross-build for Android
ifeq ($(ANDROID),1)
BUILDMODE := c-shared
BUILDEXT := so
HOST_GOOS := android
HOST_GOARCH := arm64
export GOOS := $(HOST_GOOS)
export GOARCH := $(HOST_GOARCH)
export CC := aarch64-linux-android24-clang
else
BUILDMODE := c-archive
BUILDEXT := a
endif

# Build output
MODROOT=src
BUILDDIR ?= $(CURDIR)/build
TMPROOTDIR ?= $(CURDIR)/.goroot
DESTDIR ?= $(CURDIR)/bin/$(HOST_GOOS)-$(HOST_GOARCH)

# Some specifics on macOS
ifeq ($(HOST_GOOS),darwin)
# Include sysroot
SDKROOT ?= $(shell xcrun --sdk macosx --show-sdk-path)
export CGO_CFLAGS := -isysroot $(SDKROOT)
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

build: $(BUILDDIR)/libwg-go.$(BUILDEXT)
version-header: $(BUILDDIR)/wireguard-go-version.h

$(BUILDDIR)/libwg-go.$(BUILDEXT): export CGO_ENABLED := 1
$(BUILDDIR)/libwg-go.$(BUILDEXT): $(GOROOT)/.prepared go.mod
	go build -C $(MODROOT) -ldflags=-w -trimpath -v \
		-o "$(BUILDDIR)/libwg-go.$(BUILDEXT)" \
		-buildmode=$(BUILDMODE)
	rm -f "$(BUILDDIR)/libwg-go.h"

$(DESTDIR)/wireguard-go-version.h: go.mod $(GOROOT)/.prepared
	sed -E -n 's/.*golang\.zx2c4\.com\/wireguard +v[0-9.]+-[0-9]+-([0-9a-f]{8})[0-9a-f]{4}.*/#define WIREGUARD_GO_VERSION "\1"/p' "$<" > "$@"

clean:
	rm -rf "$(BUILDDIR)" "$(DESTDIR)"

install: build
	mkdir -p "$(DESTDIR)/lib"
	mkdir -p "$(DESTDIR)/include"
	cp "$(BUILDDIR)/libwg-go.$(BUILDEXT)" "$(DESTDIR)/lib"
	cp "wireguard.h" "$(DESTDIR)/include"
	cp "module.modulemap" "$(DESTDIR)/include"

.PHONY: clean build version-header install
