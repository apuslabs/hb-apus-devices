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

Arrows point from a device to the Apus and measurement devices it resolves
through AO-Core. The **Depends-on** header of each specification also lists
the HyperBEAM core devices it uses, such as `relay@1.0`.

```text
agent@1.0
   |
   v
inference@1.0 ------------- tee=true -------------> sev_gpu@1.0
   ^                                                     ^
   |                                                     |
inference_receipt@1.0 -----> gpu_inventory@1.0           |
   |                              ^                      |
   |                              |                      |
   +--------------------> inference_measurement@1.0 -----+
                                  |
                                  v
                          measurement@1.0 (AMD SEV-SNP)
```

Together they form an attestation chain for a single completion:

- `sev_gpu@1.0` collects evidence from the NVIDIA GPU in confidential-computing
  mode for a nonce chosen by the caller. `inference@1.0` attaches it to a
  completion requested with `tee=true`, bound to the public request, the
  runtime's response and the AO-Core execution link.
- `gpu_inventory@1.0` reports the host's GPU and PCIe layout and a digest that
  is stable for an unchanged layout and driver.
- `inference_measurement@1.0` reads the inventory from `gpu_inventory@1.0`
  and binds its digest and the caller's nonce into the nonce of a fresh AMD
  SEV-SNP measurement produced by `measurement@1.0`, and requests fresh GPU
  evidence from `sev_gpu@1.0` for the measurement envelope. On a node
  without `measurement@1.0` it returns an observation envelope with the same
  inventory, GPU evidence and binding, explicitly labelled `host-observed`.
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

The public endpoint is served through a gateway operated by Apus Network,
which is not part of this repository. The gateway answers `/~inference@1.0/`
requests without `tee=true` from the model runtime directly; attested
completions (`tee=true`) and every other path are resolved by the HyperBEAM
node. For each attested completion, the gateway publishes the request's chat
messages and generation parameters, the model response and the GPU
attestation to Arweave as a permanent, public data item. Attested
completions on the public endpoint are public by design, so anyone can verify
them; for content that must stay private, use a completion without
`tee=true` or a node you operate.

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
`make eunit-all` runs the suites of every device in the repository,
including the vendored ones, together with the HyperBEAM core suites. `make help` lists every target.

Native assets are built on the Linux target host before packaging:

```bash
make setup-cc            # optional sev_gpu@1.0 NIF backend (NVIDIA attestation SDK)
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

`make preload` writes the store to `_build/apus-device-store` (set
`PRELOADED_STORE` to change it) and marks it complete only after every
device is written; `scripts/local-node.sh` starts only from a complete
store. The path differs from HyperBEAM's built-in default store
(`_build/preloaded-store`), which a HyperBEAM VM started from the repository
root opens on its own.

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

`make publish` requires committed device sources and the HyperBEAM commit
pinned in `rebar.config`. It writes [`PUBLISH.md`](PUBLISH.md) with the
signer address, the source commit, the HyperBEAM commit and the
specification and implementation IDs of every device, and keeps the raw
output in `_build/publish.log`. Signatures are salted, so every signing
produces new message IDs; the IDs in `PUBLISH.md` identify the published
messages. If an upload fails, the run stops: the devices published before it
remain on Arweave, and their IDs are written to
`_build/publish.log.partial.md`.

## Recipes

[`docs/recipes/`](docs/recipes/) holds one directory per device with
runnable examples. Each file becomes a Device-Recipe message whose
`recipe-for-device` tag is the specification ID of its device.

```bash
make recipes WALLET=/path/to/wallet.json           # sign against the local store and print the IDs
make publish-recipes WALLET=/path/to/wallet.json   # sign against PUBLISH.md, upload, update the ledger
```

`make publish-recipes` binds every recipe to the Device-Specification ID in
`PUBLISH.md` and requires `WALLET` to be the signer recorded there, so the
recipes appear with the published devices. It fails while `PUBLISH.md` lists
no published device. `make recipes` is a dry run against the preloaded store
in `PRELOADED_STORE`, rebuilt by `make preload` when a device source is newer
than the store. `RECIPE_SPECS` selects another source for either target: a
preloaded store directory or a publication record. Each uploaded recipe is
appended to [`docs/recipes/PUBLISHED.md`](docs/recipes/PUBLISHED.md) as soon
as the bundler accepts it.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/smoke-test.sh` | Probe the six devices on a running node |
| `scripts/local-node.sh` | Run a background node from a preloaded store |
| `scripts/publish-record.sh` | Render `PUBLISH.md` from the output of `make publish` |
| `scripts/publish-recipes.escript` | Sign and upload the Device-Recipe messages |
| `scripts/update-store-device.escript` | Repackage one device into an existing preloaded store, signed by the store's signer, and keep the other devices unchanged |
| `scripts/setup-measurement.sh` | Build the SNP NIF of the vendored `snp@1.0` device |
| `scripts/agent-test.lua` | Lua checks for `agent@1.0`, run in process through `lua@5.3a` |

## Repository layout

```text
src/                     device modules, one Device Forge root per device
docs/spec/               device specifications (Device-Specification bodies)
docs/*.md                operator guides for inference@1.0 and sev_gpu@1.0
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
| GPU attestation | NVIDIA Attestation SDK (NVAT) 1.2 with `nvattest` on the host; the optional NIF backend builds against [`NVIDIA/attestation-sdk`](https://github.com/NVIDIA/attestation-sdk) at `73efa3ac1bec28ed7d7f0c0811a6c993e722dbd4` (`make setup-cc`) |
| Model runtime | SGLang with an OpenAI-compatible chat-completions API |

`rebar.config` pins both the HyperBEAM dependency and the Device Forge plugin
to `apuslabs/HyperBEAM` at `28baa3d27d70c4268f439587ba0398fb7771e0e3`: the
upstream `permaweb/HyperBEAM` edge commit
`2c03978a3d201444bf7aada3eb35809153e41ef3` merged with AO-Core `vary`, which
projects handler inputs through each handler's `-spec`. `inference@1.0` speaks
the OpenAI chat-completions protocol, so other compatible runtimes plug in
through node options.
