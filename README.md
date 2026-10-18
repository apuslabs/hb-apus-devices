# Apus Network HyperBEAM Devices

AO-Core devices for verifiable AI inference on HyperBEAM, built and maintained
by [Apus Network](https://apus.network). They serve OpenAI-compatible inference
from a confidential-computing GPU node, attest the hardware that served each
answer, sign a receipt for every completion, and run agents on top of that
inference. Every step is an AO-Core resolution, so the same devices compose
with each other and with the rest of a HyperBEAM node.

The devices are packaged with HyperBEAM Device Forge. Each one is published on
Arweave as a signed Device-Specification message, whose body is the device's
specification in [`docs/spec/`](docs/spec/), and a Device-Implementation
message that carries its BEAM archive.

## Devices

| Device | Module | Purpose | Specification |
|---|---|---|---|
| `inference@1.0` | `dev_inference` | OpenAI-compatible chat completions relayed to the node's model runtime, with NVIDIA GPU TEE attestation on request (`tee=true`) | [inference.md](docs/spec/inference.md) |
| `inference_receipt@1.0` | `dev_inference_receipt` | Completions through `inference@1.0` with a node-signed receipt over the request, the response, the GPU inventory and a fresh measurement | [inference_receipt.md](docs/spec/inference_receipt.md) |
| `inference_measurement@1.0` | `dev_inference_measurement` | Fresh hardware measurement through `measurement@1.0` with the GPU inventory digest bound into its nonce | [inference_measurement.md](docs/spec/inference_measurement.md) |
| `gpu_inventory@1.0` | `dev_gpu_inventory` | Host-observed GPU and PCIe inventory with a stable digest | [gpu_inventory.md](docs/spec/gpu_inventory.md) |
| `sev_gpu@1.0` | `dev_sev_gpu` | NVIDIA confidential-computing GPU evidence for a caller-chosen nonce, and its verification | [sev_gpu.md](docs/spec/sev_gpu.md) |
| `agent@1.0` | `dev_agent` | ReAct agent loop over `inference@1.0` with built-in AO-Core tools | [agent.md](docs/spec/agent.md) |

Each specification is the normative description of its device: keys,
request and response formats, node options, errors and security model.

## How the devices compose

Arrows point from a device to the devices it resolves through AO-Core.

```text
agent@1.0
  |
  v
inference@1.0 ---------------- tee=true ----------> sev_gpu@1.0
  ^                                                   NVIDIA GPU TEE evidence
  |
inference_receipt@1.0 ----------------------------> gpu_inventory@1.0
  |                                                   GPU and PCIe inventory
  |
  +-----------------------------------------------> inference_measurement@1.0
                                                      |  inventory digest bound
                                                      |  into a fresh measurement
                                                      v
                                                    measurement@1.0 (AMD SEV-SNP)
```

Together they form an attestation chain for a single completion:

- `sev_gpu@1.0` collects evidence from the NVIDIA GPU in confidential-computing
  mode for a nonce chosen by the caller. `inference@1.0` attaches it to a
  completion requested with `tee=true`, bound to the generation parameters.
- `gpu_inventory@1.0` reports the host's GPU and PCIe layout and a digest that
  is stable for an unchanged layout and driver.
- `inference_measurement@1.0` binds the inventory digest and the caller's
  nonce into the nonce of a fresh AMD SEV-SNP measurement produced by
  `measurement@1.0`. Without `measurement@1.0` it returns an explicitly
  lower-trust observation.
- `inference_receipt@1.0` runs the completion through `inference@1.0`,
  collects the inventory and a fresh measurement, and signs a receipt that a
  third party can check against the AO-Core HashPath of the execution.
- `agent@1.0` drives a ReAct loop whose model calls resolve through
  `inference@1.0`.

## Reference deployment

[https://hb.apus.network](https://hb.apus.network) is the reference
deployment: a HyperBEAM node in an AMD SEV-SNP guest with an NVIDIA H100 GPU
in confidential-computing mode. It runs the six devices and the vendored
measurement devices from one preloaded store, and its model runtime is SGLang
serving `google/gemma-4-26B-A4B-it`.

The public endpoint is fronted by a gateway operated by Apus Network. The
gateway publishes the record of every successful attested completion
(`tee=true`) and every successful `inference_receipt@1.0` completion to
Arweave as a permanent data item. Call a node port directly to exercise the
devices without that step.

## Vendored PermawebOS devices

[`vendor/permaweb-os/`](vendor/permaweb-os/) holds unchanged upstream
sources of `measurement@1.0`, `system@1.0` and `snp@1.0` from PermawebOS at the
revision recorded in [`UPSTREAM.md`](vendor/permaweb-os/UPSTREAM.md). They are
packaged and preloaded together with the Apus devices so that
`inference_measurement@1.0` can produce SEV-SNP measurements. Apus Network
does not publish them.

## Requirements

- Erlang/OTP 27, rebar3, git, GNU Make and bash.
- `curl` for the smoke test.
- On the Linux target host, for the native assets: `cmake`, `clang`, `cargo`,
  `pkg-config` and the development packages of libcurl, OpenSSL, libxml2,
  xmlsec1 and spdlog (`make check-nvat-deps` reports the missing ones).

## Build and test

```bash
make compile   # compile the devices and the pinned HyperBEAM
make test      # run the EUnit suites of the six devices
make package   # write one BEAM archive per device to _build/device-packages
make verify    # load every archive with HyperBEAM's runtime loader
```

`make test` packages every device, builds a fresh test store and runs the
suites against it. It needs no GPU, SEV-SNP guest or model runtime.
`make help` lists every target.

Native assets are built on the Linux target host before packaging:

```bash
make setup-cc            # sev_gpu@1.0 NIF and NVIDIA attestation SDK libraries
make setup-measurement   # SNP NIF of the vendored snp@1.0 device
```

## Run a local node

Node options, such as the model runtime address and credentials, measurement
settings and native paths, are read from the node's configuration
(`config.flat` in the working directory, or the file named by `HB_CONFIG`).
Each specification lists the options of its device.

Start an interactive node with every device preloaded:

```bash
make local
```

Or build a signed preloaded store and run a background node from it:

```bash
make preload WALLET=/path/to/wallet.json
scripts/local-node.sh start          # http://localhost:8734 by default
make smoke                           # probe the six devices
scripts/local-node.sh stop
```

`make smoke HB_URL=...` probes any node. Probes for hardware or a model
runtime that the node does not have report `FAIL` with the node's response;
`scripts/smoke-test.sh meta gpu_inventory` runs a subset.

## Publish

Publishing signs every message with the keyfile in `WALLET` and uploads it to
Arweave, where it is permanent. Only the six Apus devices are published.

```bash
make publish-dry-run WALLET=/path/to/wallet.json   # sign and print the IDs
make publish WALLET=/path/to/wallet.json           # upload and write PUBLISH.md
```

`make publish` requires committed device sources. It writes
[`PUBLISH.md`](PUBLISH.md) with the signer address, the source commit, the
HyperBEAM commit and the specification and implementation IDs of every
device, and keeps the raw output in `_build/publish.log`. Signatures are
salted, so every signing produces new message IDs; the IDs in `PUBLISH.md`
identify the published messages.

## Recipes

[`docs/recipes/`](docs/recipes/) holds one directory per device with
runnable examples. Each file becomes a Device-Recipe message whose
`recipe-for-device` tag is the specification ID of its device.

```bash
make recipes WALLET=/path/to/wallet.json           # sign and print the IDs
make publish-recipes WALLET=/path/to/wallet.json   # upload and update the ledger
```

The specification IDs come from `PRELOADED_STORE` (default
`_build/preloaded-store`, built by `make preload` when it is missing). Point
it at the store a node runs to bind recipes to that node's devices, or set
`RECIPE_SPECS=PUBLISH.md` to bind them to the Device-Specification messages
published on Arweave. Uploaded rounds are listed in
[`docs/recipes/PUBLISHED.md`](docs/recipes/PUBLISHED.md).

## Scripts

| Script | Purpose |
|---|---|
| `scripts/smoke-test.sh` | Probe the six devices on a running node |
| `scripts/local-node.sh` | Run a background node from a preloaded store |
| `scripts/publish-record.sh` | Render `PUBLISH.md` from the output of `make publish` |
| `scripts/publish-recipes.escript` | Sign and upload the Device-Recipe messages |
| `scripts/update-store-device.escript` | Repackage one device into an existing preloaded store and keep the other devices unchanged |
| `scripts/setup-measurement.sh` | Build the SNP NIF of the vendored `snp@1.0` device |

## Repository layout

```text
src/                     device modules, one Device Forge root per device
docs/spec/               device specifications (Device-Specification bodies)
docs/recipes/            Device-Recipe sources, one directory per device
native/dev_sev_gpu_nif/  NIF that links sev_gpu@1.0 to the NVIDIA attestation SDK
vendor/permaweb-os/      vendored PermawebOS measurement devices
scripts/                 node, smoke-test and publishing tools
```

## Device conventions

Changes to the devices keep these AO-Core conventions:

- Handlers have the form `Key(Base, Req, Opts)` and return `{ok, Msg}` or
  `{error, Reason}`.
- Devices call each other only through `hb_ao:resolve` by device name, and
  reach the network only through HyperBEAM's HTTP stack.
- Backends, peers, credentials, file paths and executables are node options
  read with `hb_opts:get/3`, never request or base message keys.
- Every exported key has a single-clause `-spec`. The pinned HyperBEAM
  projects request inputs through that `-spec`, so request map types include
  `_ => _` to keep keys that are not declared individually.
- EUnit tests live in the device module, where `make test` runs them.

## Compatibility

The devices are built and tested against:

| Component | Version |
|---|---|
| HyperBEAM and Device Forge | [`apuslabs/HyperBEAM`](https://github.com/apuslabs/HyperBEAM) at `28baa3d27d70c4268f439587ba0398fb7771e0e3` |
| Erlang/OTP | 27 |
| rebar3 | 3.27 |
| PermawebOS measurement devices | [`permaweb/os`](https://github.com/permaweb/os) at `63f88cc3a73af0e5af13b58887b2870d8b486c48` |
| Host | Linux x86_64 AMD SEV-SNP guest with an NVIDIA H100 in confidential-computing mode |
| GPU attestation | NVIDIA attestation SDK, built by `make setup-cc` |
| Model runtime | SGLang with an OpenAI-compatible chat-completions API |

The HyperBEAM pin is the upstream `permaweb/HyperBEAM` edge line at
`2c03978a3d201444bf7aada3eb35809153e41ef3` with AO-Core `vary`, which projects
handler inputs through each handler's `-spec`. `rebar.config` pins both the
dependency and the Device Forge plugin to this commit. `inference@1.0` speaks
the OpenAI chat-completions protocol, so other compatible runtimes plug in
through node options.
