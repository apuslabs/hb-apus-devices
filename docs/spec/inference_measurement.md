# inference_measurement@1.0

GPU-aware adapter over the node's `measurement@1.0` protocol.

When the node exposes `measurement@1.0`, the device keeps its measured
subject (`system@1.0/all` and `meta@1.0/info`) and binds a GPU inventory
digest, plus an optional caller nonce, into the nonce of a fresh hardware
measurement. Without `measurement@1.0` it returns an explicitly lower-trust
observation.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `boot` | GET/POST | Boot-time measurement envelope with the GPU inventory digest bound in. |
| `fresh` | POST | Fresh measurement. `nonce` (hex or binary) is mixed into the bound nonce. |
| `verify` | POST | Verifies an `envelope` (or `body`) produced by `boot` or `fresh`. |
| `snapshot` | GET | Volatile GPU runtime facts from `nvidia-smi`; not part of any digest. |

## Request keys

- `nonce`: caller freshness value for `fresh`.
- `envelope` or `body`: measurement envelope for `verify`.
- `measurement-mode`: `auto` (default), `observation-only` or `hook-body`.
  Read from the request, then the base message, then node options.
- `gpu-inventory-root`: sysfs root override used by tests.

## Responses

`boot` and `fresh` return a `body` with the measurement envelope, the GPU
inventory digest and the binding nonce. `verify` delegates to
`measurement@1.0/verify` when the node has it; otherwise it checks an
observation envelope and returns `verified`, `provenance-class=host-observed`
and `observation-id`, or 400 with `error=invalid-observation`. `snapshot` returns `supported`, `devices` and `errors`.
`snapshot` reports `supported=false` with an `errors` entry when
`nvidia-smi` cannot be queried.

## Trust boundary

GPU facts are host-observed. The trust anchor is the host measurement chain
(SNP on the APUS H100 guest), not the GPU.
