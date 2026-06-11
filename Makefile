.PHONY: compile package verify test local publish setup-inference setup-cc check-nvat-deps clean-publish

HYPERBEAM_REF = df62acf0f2a5404822888f09c846d02a361f7fd2
WALLET ?= $(HOME)/.aos.json

DETERMINISTIC_INFERENCE_BRANCH ?= main
DETERMINISTIC_INFERENCE_DIR = _build/deterministic-inference
DETERMINISTIC_INFERENCE_REPO = https://github.com/apuslabs/deterministic-inference.git

NVAT_SDK_BRANCH ?= main
NVAT_SDK_REPO = https://github.com/NVIDIA/attestation-sdk.git
NVAT_SDK_DIR = _build/attestation-sdk
NVAT_BUILD_DIR = $(NVAT_SDK_DIR)/nv-attestation-sdk-cpp/build
DEV_SEV_GPU_NIF_DIR = _build/dev_sev_gpu_nif
DEV_SEV_GPU_PRIV = priv/dev_sev_gpu

compile:
	rebar3 compile

package:
	rebar3 device package

verify:
	rebar3 device verify

test:
	rebar3 device test --device-roots dev_agent,dev_inference,dev_sev_gpu

local:
	rebar3 device local

publish:
	@test -f "$(WALLET)" || (echo "Missing wallet: $(WALLET)" && exit 1)
	@TS=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	OUT=$$(mktemp); \
	set -o pipefail; \
	rebar3 device publish --key "$(WALLET)" 2>&1 | tee "$$OUT"; \
	{ \
		echo "# Published Apus HyperBEAM Devices"; \
		echo ""; \
		echo "- Published at: $$TS"; \
		echo "- Wallet: $(WALLET)"; \
		echo "- HyperBEAM ref: $(HYPERBEAM_REF)"; \
		echo ""; \
		echo "## Device IDs"; \
		echo ""; \
		grep 'device publish:' "$$OUT" | sed -E 's/^.*device publish: /- /'; \
	} > PUBLISH.md; \
	rm -f "$$OUT"

setup-python:
	@if ! command -v python3 > /dev/null; then \
		echo "Error: Python3 is not installed."; \
		exit 1; \
	fi
	@if ! command -v uv > /dev/null; then \
		echo "Installing uv package manager..."; \
		curl -LsSf https://astral.sh/uv/install.sh | sh; \
	fi

$(DETERMINISTIC_INFERENCE_DIR):
	@echo "Cloning deterministic-inference repository..." && \
	git clone -b $(DETERMINISTIC_INFERENCE_BRANCH) $(DETERMINISTIC_INFERENCE_REPO) $(DETERMINISTIC_INFERENCE_DIR) --single-branch

setup-inference: setup-python $(DETERMINISTIC_INFERENCE_DIR)
	@echo "Setting up deterministic-inference..." && \
	cd $(DETERMINISTIC_INFERENCE_DIR) && uv sync

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
		echo "Error: Missing dependencies for NVIDIA attestation SDK:$$missing"; \
		exit 1; \
	fi

$(NVAT_SDK_DIR):
	@git clone -b $(NVAT_SDK_BRANCH) $(NVAT_SDK_REPO) $(NVAT_SDK_DIR) --single-branch

$(NVAT_BUILD_DIR)/libnvat.so: check-nvat-deps $(NVAT_SDK_DIR)
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
	mkdir -p $(DEV_SEV_GPU_PRIV)/lib
	cp $(DEV_SEV_GPU_NIF_DIR)/dev_sev_gpu_nif.so $(DEV_SEV_GPU_PRIV)/
	cp $(NVAT_BUILD_DIR)/libnvat.so* $(DEV_SEV_GPU_PRIV)/lib/ 2>/dev/null || true

setup-cc: $(DEV_SEV_GPU_NIF_DIR)/dev_sev_gpu_nif.so
	@echo "Installed dev_sev_gpu NIF assets in $(DEV_SEV_GPU_PRIV)."

clean-publish:
	rm -f PUBLISH.md PUBLISH.md.tmp
