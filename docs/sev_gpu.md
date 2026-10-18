# GPU attestation chain: operator guide

Apus Network nodes attest their inference hardware with three devices:

| Device | Role |
|---|---|
| `gpu_inventory@1.0` | Host-observed GPU and PCIe inventory with a canonical digest. |
| `sev_gpu@1.0` | NVIDIA confidential-computing GPU attestation through NVIDIA's attestation SDK (NVAT). |
| `inference_measurement@1.0` | Binds the inventory digest and a request nonce into one digest that is the nonce of both the AMD SEV-SNP host measurement and the GPU attestation. |

The specifications in `docs/spec/` define their behaviour. This guide covers
building the native GPU attestation backend, packaging it, and checking a
node. The reference deployment is https://hb.apus.network: an NVIDIA H100 in
confidential-computing mode inside an AMD SEV-SNP guest.

## Native backend

`sev_gpu@1.0` calls NVAT through a NIF. The build needs a Linux host with
`cmake`, `clang`, `cargo`, Erlang/OTP (`erl`, `erlc` and `erl_nif.h`) and the
development packages for `libcurl`, `openssl`, `libxml2`, `xmlsec1` and
`spdlog`.

```bash
make setup-cc
```

This clones and builds the NVAT SDK under `_build/attestation-sdk/`, then
builds `native/dev_sev_gpu_nif/` with CMake into `_build/dev_sev_gpu_nif/`:

| File | Purpose |
|---|---|
| `dev_sev_gpu_nif.so` | The NIF, linked against `libnvat`. |
| `dev_sev_gpu_nif.beam` | The `dev_sev_gpu_nif` module that owns the NIF. |

Device Forge packages the device's native assets from `priv/dev_sev_gpu/`,
which must hold the NIF, its module and the NVAT library before
`make package`:

```bash
mkdir -p priv/dev_sev_gpu/lib
cp _build/dev_sev_gpu_nif/dev_sev_gpu_nif.so \
   _build/dev_sev_gpu_nif/dev_sev_gpu_nif.beam priv/dev_sev_gpu/
cp -P _build/attestation-sdk/nv-attestation-sdk-cpp/build/libnvat.so* \
   priv/dev_sev_gpu/lib/
```

```text
priv/dev_sev_gpu/
  dev_sev_gpu_nif.beam
  dev_sev_gpu_nif.so
  lib/libnvat.so*
```

The NIF's run-time search path is `$ORIGIN/lib` and `$ORIGIN/../lib`, so it
finds `libnvat` in `lib/` next to itself, both in `priv/dev_sev_gpu/` and in
the extracted implementation archive. No environment variable is needed:

```bash
readelf -d priv/dev_sev_gpu/dev_sev_gpu_nif.so | grep -E 'RUNPATH|RPATH'
```

Expected: `[$ORIGIN/lib:$ORIGIN/../lib]`.

The `dev_sev_gpu_nif` module always carries the name the library declares, so
the NIF loads whatever generated name Device Forge gives the device module. When the module is present but the library does not load (for
example because `libnvat` is missing), the node prints one line on standard
error:

```text
sev_gpu@1.0: NVAT NIF not loaded from <path>: <reason>
```

## Command-line backend

Without the NIF, `sev_gpu@1.0` runs NVIDIA's `nvattest` tool directly (no
shell) from `sev-gpu-nvattest-path`, `/usr/bin/nvattest` by default. Install
it with the NVAT SDK; `nvattest version` prints the installed version. `verify`
on this backend needs an `nvattest` that supports `--gpu-evidence-source file`.

## Node options

| Option | Default | Device |
|---|---|---|
| `sev-gpu-backend` | `auto` | `sev_gpu@1.0`: `auto`, `nif` or `nvattest` |
| `sev-gpu-nvattest-path` | `/usr/bin/nvattest` | `sev_gpu@1.0` |
| `sev-gpu-nvattest-timeout` | `60000` (ms) | `sev_gpu@1.0` |
| `sev-gpu-scratch-dir` | `/tmp` | `sev_gpu@1.0`: evidence files for `verify` |
| `gpu-inventory-root` | `/sys` | `gpu_inventory@1.0` |
| `gpu-inventory-nvidia-smi-path` | `nvidia-smi` | `gpu_inventory@1.0`: absolute path or name in `PATH` |
| `gpu-inventory-nvidia-smi-timeout` | `10000` (ms) | `gpu_inventory@1.0` |
| `measurement-mode` | `auto` | `inference_measurement@1.0` |
| `inference-measurement-sev-guest-path` | `/dev/sev-guest` | `inference_measurement@1.0` |

Set `sev-gpu-backend` to `nif` on a node that must never fall back to
`nvattest`; `generate` then fails with `nif_unavailable` when the NIF is not
loaded.

## Checking a node

```bash
HB=${HB:-http://localhost:8734}
NONCE=$(openssl rand -hex 32)
curl -s "$HB/~sev_gpu@1.0/generate?nonce=$NONCE" \
  | python3 -c 'import json, sys; r = json.load(sys.stdin); print(r["nonce"] == sys.argv[1], r["verified"])' "$NONCE"
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_measurement@1.0/fresh?nonce=$NONCE" \
  | python3 -c 'import json, sys; m = json.load(sys.stdin); print(m["type"], m["gpu-tee"]["verified"], m["cpu-tee"]["verified"])'
```

Expected on a healthy H100 node in an SEV-SNP guest: `True True`, then
`lapee-measurement true true`. The recipes in `docs/recipes/sev_gpu/`,
`docs/recipes/gpu_inventory/` and `docs/recipes/inference_measurement/` show
more checks, including recomputing the inventory digest and the binding.

## Tests

```bash
rebar3 device test --device-src=src,vendor/permaweb-os/src \
  --devices=dev_sev_gpu,dev_gpu_inventory,dev_inference_measurement
```

The tests cover nonce validation, the claims rule, both backends (with
stand-in executables), inventory parsing and the measurement binding. Tests
that need a real GPU run on a confidential-computing host and skip elsewhere.
