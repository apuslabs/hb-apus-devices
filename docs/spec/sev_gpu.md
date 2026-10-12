# sev_gpu@1.0

NVIDIA GPU TEE attestation through a NIF linked against NVIDIA's attestation
SDK (NVAT), with a fallback to `/usr/bin/nvattest`.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `generate` | GET/POST | Collects GPU evidence for `nonce`, verifies it locally and returns JSON. |
| `verify` | POST | Verifies evidence JSON sent in `body`. |

## `generate`

- `nonce`: hex freshness value (64 hex characters for NVAT).

Returns JSON with `evidences` (serialized evidence for a remote verifier),
`claims`, `eat` (detached Entity Attestation Token), `verified` and the echoed
`nonce`. When the GPU or SDK cannot produce evidence the response still
returns 200 with `verified=false`, empty `claims` and `evidences=null`.

## `verify`

- `body`: the `evidences` JSON from a previous `generate`.

Returns the binary `true` or `false`.

## Native assets

The NIF is packaged in the Forge implementation archive under
`priv/dev_sev_gpu/` and loaded from `hb_device_archive:implementation_dir/1`.
