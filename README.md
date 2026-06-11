# Apus HyperBEAM Devices

External HyperBEAM Device Forge repository for Apus devices:

- `agent@1.0`
- `inference@1.0`
- `sev_gpu@1.0`

This repository is pinned to HyperBEAM `df62acf0f2a5404822888f09c846d02a361f7fd2`, the PR #915 Device Forge baseline.

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

`sev_gpu@1.0` can package NVIDIA GPU attestation assets under `priv/dev_sev_gpu/`:

```sh
make setup-cc
```

`inference@1.0` can use the Apus deterministic inference backend:

```sh
make setup-inference
```

## Local Node

```sh
rebar3 device local
```

## Publish

Publishing signs and uploads Device Specification and Device Implementation messages with `~/.aos.json` by default:

```sh
make publish
```

The publish output is recorded in `PUBLISH.md`.
