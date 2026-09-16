# Apus HyperBEAM Devices

External HyperBEAM Device Forge repository for Apus devices:

- `agent@1.0`
- `inference@1.0`
- `sev_gpu@1.0`
- `gpu_inventory@1.0`
- `inference_measurement@1.0`
- `measurement@1.0`, `system@1.0`, `snp@1.0` (unchanged PermawebOS sources)
- `inference_receipt@1.0`

This repository is pinned to the official HyperBEAM `edge` commit
`2c03978a3d201444bf7aada3eb35809153e41ef3`.

## Build

```sh
rebar3 compile
```

## Package and Verify

```sh
make package
make verify
make test
```

## Optional Native Setup

Build Sam's SNP backend on the Linux target before packaging:

```sh
make setup-measurement
```

The pinned sources and provenance are in `vendor/permaweb-os/UPSTREAM.md`.
`inference_measurement@1.0` calls the standard measurement protocol and binds
the GPU inventory and request digest into its fresh nonce. System facts come
from upstream `system@1.0/all`; the standard measured subject remains the
system report plus `meta@1.0/info`.

`sev_gpu@1.0` can package NVIDIA GPU attestation assets under `priv/dev_sev_gpu/`:

```sh
make setup-cc
```

`inference@1.0` relays chat requests to a llama.cpp server at
`http://localhost:30001` by default. See [inference and receipt configuration](docs/inference.md)
for backend routing, execution metadata, verification, and receipt publishing.

To install the separate Apus deterministic inference backend:

```sh
make setup-inference
```

## Local Node

```sh
make local
```

## Offline Demo

The trust-gradient and remote-observation demo is self-contained under
`demo/`:

```sh
python3 -m http.server 8088 --directory demo
```

Open `http://127.0.0.1:8088/`. It does not claim GPU attestation or inference
correctness, and the RTX 4090 panel is explicitly marked as a separate
`host-observed` fixture.

## Publish

Publishing signs and uploads Device Specification and Device Implementation messages with `~/.aos.json` by default:

```sh
make publish
```

The publish output is recorded in `PUBLISH.md`.
