# sev_gpu@1.0

NVIDIA GPU TEE attestation through a NIF linked against NVIDIA's attestation
SDK (NVAT), with a fallback to `/usr/bin/nvattest`.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `generate` | GET/POST | Collects GPU evidence for `nonce`, verifies it locally and returns JSON. |
| `verify` | POST | Verifies evidence JSON sent in `body`. |

## `generate`

- `nonce`: hex freshness value (64 hex characters for NVAT). Required.

Returns JSON with `evidences` (serialized evidence for a remote verifier),
`claims`, `eat` (detached Entity Attestation Token), `verified` and the echoed
`nonce`.

`verified` is this node's own check of the evidence it just collected; it is not
proof to a third party. A remote verifier must call `verify` and must confirm
the echoed `nonce` is the one it chose, because the report is only as fresh as
that nonce.

Errors: `nonce_required` when the request carries no nonce, `invalid_nonce`
when it is not hex, and `{nvat_error, Reason}` when the GPU or SDK cannot
produce evidence. The device never substitutes a default nonce; a request
without one would otherwise return a replayable report that still reads
`verified=true`.

## `verify`

- `body`: the `evidences` JSON from a previous `generate`.

Returns the binary `true` or `false`. Verification needs the NVAT NIF: when
the node cannot load it, `verify` returns `nif_not_loaded`.

## Native assets

The NIF is packaged in the Forge implementation archive under
`priv/dev_sev_gpu/` and loaded from `hb_device_archive:implementation_dir/1`.
