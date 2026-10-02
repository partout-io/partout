# SPDX-License-Identifier: MIT
#
# Copyright (C) 2018-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.

# First target is default target
all: install

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

# Always let Go check its compilation cache when invoked directly.
# The XCFramework builder also caches the completed archive per Apple slice.
build: export CGO_ENABLED := 1
build: $(GOROOT)/.prepared
	go build -ldflags="$(GO_LDFLAGS)" -trimpath -v \
		-o "$(BUILDDIR)/libwg-go.$(BUILDEXT)" \
		-buildmode=$(BUILDMODE)
	rm -f "$(BUILDDIR)/libwg-go.h"

clean:
	rm -rf "$(BUILDDIR)" "$(DESTDIR)" "$(TMPROOTDIR)"

install: build
	mkdir -p "$(DESTDIR)/lib"
	cp $(BUILDDIR)/libwg-go.* "$(DESTDIR)/lib"
	cp -pR "include" "$(DESTDIR)"

.PHONY: all clean build install
