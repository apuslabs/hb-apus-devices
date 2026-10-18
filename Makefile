# Build, test, package and publish the Apus Network HyperBEAM devices.
# Run `make help` for the list of targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Device Forge roots of the six devices published by Apus Network.
DEVICES = dev_agent,dev_inference,dev_sev_gpu,dev_gpu_inventory,dev_inference_measurement,dev_inference_receipt
# Source roots scanned by Device Forge: the Apus devices and the vendored
# PermawebOS measurement devices they compose with.
DEVICE_SOURCES = src,vendor/permaweb-os/src
# HyperBEAM commit pinned in rebar.config.
HYPERBEAM_REF := $(shell sed -n 's/.*{ref, *"\([0-9a-f]\{40\}\)"}.*/\1/p' rebar.config | head -n 1)

# Signing keyfile for preload, publish and recipe targets. It has no default:
# pass it explicitly, for example `make publish WALLET=/path/to/wallet.json`.
WALLET ?=
# Preloaded store built by `make preload`. It is kept apart from
# HyperBEAM's built-in default store path (_build/preloaded-store), which any
# HyperBEAM VM started from the repository root opens.
PRELOADED_STORE ?= _build/apus-device-store
# Written by `make preload` only after the store is complete.
PRELOAD_MARKER = $(PRELOADED_STORE)/.preloaded
# Files packaged into the preloaded store: the store is rebuilt when one of
# them is newer than PRELOAD_MARKER.
PRELOAD_INPUTS := $(shell find src docs/spec vendor/permaweb-os/src \
	-type f 2>/dev/null) rebar.config rebar.lock
# Source of the specification IDs that recipes bind to: a preloaded store
# directory or a publication record written by `make publish` (PUBLISH.md).
# Unset, `make recipes` reads PRELOADED_STORE and `make publish-recipes`
# reads PUBLISH.md, so uploaded recipes reference the Device-Specification
# messages published on Arweave.
RECIPE_SPECS ?=
RECIPE_SPECS_SIGN = $(or $(RECIPE_SPECS),$(PRELOADED_STORE))
RECIPE_SPECS_UPLOAD = $(or $(RECIPE_SPECS),PUBLISH.md)
# Raw output of the last `make publish`.
PUBLISH_LOG ?= _build/publish.log
# Node probed by `make smoke`.
HB_URL ?= http://localhost:8734

# NVIDIA attestation SDK linked into the sev_gpu@1.0 NIF, pinned by commit.
NVAT_SDK_REF ?= 73efa3ac1bec28ed7d7f0c0811a6c993e722dbd4
NVAT_SDK_REPO = https://github.com/NVIDIA/attestation-sdk.git
NVAT_SDK_DIR = _build/attestation-sdk
NVAT_SDK_CHECKOUT = $(NVAT_SDK_DIR)/.checkout-$(NVAT_SDK_REF)
NVAT_BUILD_DIR = $(NVAT_SDK_DIR)/nv-attestation-sdk-cpp/build
DEV_SEV_GPU_NIF_DIR = _build/dev_sev_gpu_nif
# Native assets of sev_gpu@1.0. Device Forge packages a device root's own
# `src/<root>/priv` directory into that device's archive only.
DEV_SEV_GPU_PRIV = src/dev_sev_gpu/priv
# `yes` also copies the NVAT shared library into the sev_gpu@1.0 archive;
# `no` uses the host's NVAT installation (the libnvat package).
NVAT_BUNDLE ?= no

# A recipe target that reads PRELOADED_STORE depends on a complete store.
store_dep = $(if $(filter $(PRELOADED_STORE),$(1)),$(PRELOAD_MARKER))

.PHONY: help compile test eunit-all package verify preload local smoke \
	publish-dry-run publish recipes publish-recipes \
	setup-measurement setup-cc check-nvat-deps check-wallet check-clean \
	check-ref

help: ## List the available targets
	@echo "Apus Network HyperBEAM devices (HyperBEAM $(HYPERBEAM_REF))"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN { FS = ":.*## " } { printf "  %-18s %s\n", $$1, $$2 }'

compile: ## Compile the devices against the pinned HyperBEAM
	rebar3 compile < /dev/null

test: ## Run the EUnit suites of the six devices against a fresh test store
	rebar3 device test --device-src=$(DEVICE_SOURCES) --devices=$(DEVICES) < /dev/null

eunit-all: ## Run the device suites together with the HyperBEAM core suites
	rebar3 device test --with-core --device-src=$(DEVICE_SOURCES) < /dev/null

package: ## Write a BEAM archive per device to _build/device-packages
	rebar3 device package --device-src=$(DEVICE_SOURCES) < /dev/null

verify: ## Package every device and load each archive with the runtime loader
	rebar3 device verify --device-src=$(DEVICE_SOURCES) < /dev/null

preload: check-wallet ## Build a signed preloaded store of every device in PRELOADED_STORE
	rm -f $(PRELOAD_MARKER)
	rebar3 device preload --device-src=$(DEVICE_SOURCES) --key "$(WALLET)" \
		--output-dir $(PRELOADED_STORE) --verbose < /dev/null
	touch $(PRELOAD_MARKER)

$(PRELOAD_MARKER): $(PRELOAD_INPUTS)
	@$(MAKE) --no-print-directory preload

local: ## Start an interactive local node with every device preloaded
	rebar3 device local --device-src=$(DEVICE_SOURCES) $(if $(WALLET),--key "$(WALLET)")

smoke: ## Probe the six devices on a running node at HB_URL
	HB_URL="$(HB_URL)" scripts/smoke-test.sh

publish-dry-run: check-wallet ## Sign the six devices and print their IDs without uploading
	rebar3 device publish --device-src=$(DEVICE_SOURCES) --devices=$(DEVICES) \
		--key "$(WALLET)" --dry-run < /dev/null

publish: check-wallet check-clean check-ref ## Sign and upload the six devices to Arweave, then write PUBLISH.md
	@mkdir -p $(dir $(PUBLISH_LOG))
	@rm -f $(PUBLISH_LOG).partial.md
	@set -o pipefail; \
	if ! rebar3 device publish --device-src=$(DEVICE_SOURCES) --devices=$(DEVICES) \
		--key "$(WALLET)" < /dev/null 2>&1 | tee $(PUBLISH_LOG); then \
		echo "error: publishing stopped before every device was uploaded." >&2; \
		echo "Devices listed as 'Published device' in $(PUBLISH_LOG) are permanent on Arweave;" >&2; \
		echo "the specification of the device that stopped the run may be uploaded as well." >&2; \
		if scripts/publish-record.sh $(PUBLISH_LOG) $(HYPERBEAM_REF) \
			> $(PUBLISH_LOG).partial.md 2> /dev/null; then \
			echo "Their IDs are recorded in $(PUBLISH_LOG).partial.md." >&2; \
		else \
			rm -f $(PUBLISH_LOG).partial.md; \
		fi; \
		exit 1; \
	fi
	scripts/publish-record.sh $(PUBLISH_LOG) $(HYPERBEAM_REF) > $(PUBLISH_LOG).md
	mv $(PUBLISH_LOG).md PUBLISH.md
	@echo "Wrote PUBLISH.md"

recipes: check-wallet $(call store_dep,$(RECIPE_SPECS_SIGN)) ## Sign the recipes in docs/recipes and print their IDs
	escript scripts/publish-recipes.escript "$(RECIPE_SPECS_SIGN)" "$(WALLET)"

publish-recipes: check-wallet $(call store_dep,$(RECIPE_SPECS_UPLOAD)) ## Sign the recipes against PUBLISH.md and upload them to Arweave
	escript scripts/publish-recipes.escript "$(RECIPE_SPECS_UPLOAD)" "$(WALLET)" --upload

setup-measurement: ## Build the vendored SNP measurement NIF (Linux)
	bash scripts/setup-measurement.sh

check-wallet:
	@if [ -z "$(WALLET)" ]; then \
		echo "error: set WALLET to the signing keyfile, for example: make $(firstword $(MAKECMDGOALS)) WALLET=/path/to/wallet.json" >&2; \
		exit 1; \
	fi
	@if [ ! -f "$(WALLET)" ]; then \
		echo "error: wallet keyfile not found: $(WALLET)" >&2; \
		exit 1; \
	fi

check-clean:
	@if [ -n "$$(git status --porcelain -- src vendor native docs/spec rebar.config rebar.lock)" ]; then \
		echo "error: commit the device sources before publishing; PUBLISH.md records the commit" >&2; \
		git status --short -- src vendor native docs/spec rebar.config rebar.lock >&2; \
		exit 1; \
	fi

check-ref:
	@if ! [[ "$(HYPERBEAM_REF)" =~ ^[0-9a-f]{40}$$ ]]; then \
		echo "error: could not read the HyperBEAM commit pinned in rebar.config" >&2; \
		exit 1; \
	fi

check-nvat-deps:
	@missing=""; \
	if ! command -v cmake > /dev/null; then missing="$$missing cmake"; fi; \
	if ! command -v clang > /dev/null; then missing="$$missing clang"; fi; \
	if ! command -v cargo > /dev/null; then missing="$$missing cargo"; fi; \
	if ! pkg-config --exists libcurl 2>/dev/null; then missing="$$missing libcurl"; fi; \
	if ! pkg-config --exists openssl 2>/dev/null; then missing="$$missing openssl"; fi; \
	if ! pkg-config --exists libxml-2.0 2>/dev/null; then missing="$$missing libxml2"; fi; \
	if ! pkg-config --exists xmlsec1 2>/dev/null; then missing="$$missing xmlsec1"; fi; \
	if ! pkg-config --exists spdlog 2>/dev/null; then missing="$$missing spdlog"; fi; \
	if [ -n "$$missing" ]; then \
		echo "error: missing dependencies for the NVIDIA attestation SDK:$$missing" >&2; \
		exit 1; \
	fi

$(NVAT_SDK_CHECKOUT):
	mkdir -p $(NVAT_SDK_DIR)
	git -C $(NVAT_SDK_DIR) init -q
	git -C $(NVAT_SDK_DIR) fetch -q --depth 1 $(NVAT_SDK_REPO) $(NVAT_SDK_REF)
	git -C $(NVAT_SDK_DIR) checkout -q --detach FETCH_HEAD
	rm -f $(NVAT_SDK_DIR)/.checkout-*
	touch $@

$(NVAT_BUILD_DIR)/libnvat.so: $(NVAT_SDK_CHECKOUT) | check-nvat-deps
	cmake -S $(NVAT_SDK_DIR)/nv-attestation-sdk-cpp \
		-B $(NVAT_BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=ON
	cmake --build $(NVAT_BUILD_DIR) -j$$(nproc 2>/dev/null || sysctl -n hw.ncpu)

$(DEV_SEV_GPU_NIF_DIR)/dev_sev_gpu_nif.so: $(NVAT_BUILD_DIR)/libnvat.so
	cmake -S native/dev_sev_gpu_nif \
		-B $(DEV_SEV_GPU_NIF_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DNVAT_SDK_DIR=$(CURDIR)/$(NVAT_SDK_DIR)/nv-attestation-sdk-cpp \
		-DNVAT_BUILD_DIR=$(CURDIR)/$(NVAT_BUILD_DIR) \
		-DNVAT_DEBUG_LOG=OFF
	cmake --build $(DEV_SEV_GPU_NIF_DIR)
	mkdir -p $(DEV_SEV_GPU_PRIV)
	cp $(DEV_SEV_GPU_NIF_DIR)/dev_sev_gpu_nif.so $(DEV_SEV_GPU_NIF_DIR)/dev_sev_gpu_nif.beam \
		$(DEV_SEV_GPU_PRIV)/
	if [ "$(NVAT_BUNDLE)" = yes ]; then \
		mkdir -p $(DEV_SEV_GPU_PRIV)/lib && cp -P $(NVAT_BUILD_DIR)/libnvat.so* $(DEV_SEV_GPU_PRIV)/lib/; \
	fi

setup-cc: $(DEV_SEV_GPU_NIF_DIR)/dev_sev_gpu_nif.so ## Build the sev_gpu@1.0 NVAT NIF into src/dev_sev_gpu/priv (Linux)
	@echo "Installed the sev_gpu@1.0 NIF and its module in $(DEV_SEV_GPU_PRIV)."
