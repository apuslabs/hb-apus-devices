# inference_receipt@1.0

Receipt decorator for `inference@1.0`.

The device runs a non-streaming chat completion through `inference@1.0`,
hashes the exact request and response, collects `gpu_inventory@1.0/report`
and `inference_measurement@1.0/fresh`, and returns the runtime's JSON with a
signed `receipt` object added. Streaming requests are rejected.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `v1` | POST | Router. `/~inference_receipt@1.0/v1/chat/completions` reaches `completions`. |
| `chat` | POST | Marks a chat request and forwards to `completions`. |
| `completions` | POST | Runs the completion and attaches the receipt. |
| `models` | GET | Delegates to `inference@1.0/models` without creating a receipt. |
| `health` | GET | Delegates to `inference@1.0/health` without creating a receipt. |
| `verify-hashpath` | POST | Recomputes a recorded transcript's HashPath and compares it with the receipt's `ao-core.hashpath`. |
| `publish` | POST | Signs a receipt as an ANS-104 item and submits it to `bundler@1.0`. |

## Request (`completions`)

All `inference@1.0` request keys, plus optional execution declarations that
are copied into the receipt for a verifier to compare against the deployed
artifacts: `model-sha256`, `model-source`, `model-tx`, `model-revision`,
`runtime-name`, `runtime-version`, `runtime-build-hash`, `inference-profile`,
`workload-manifest-id`, `measurement-mode`, `gpu-inventory-root`.

These declarations are recorded, not checked. The device does not download or
hash the model.

## Response (`completions`)

The runtime JSON plus `receipt`, which contains the request and response
digests, the node address, the GPU inventory digest, the measurement
envelope (or an observation-only result when hardware measurement is
unavailable), and the node's signature. Its `ao-core` object records
`status` (`captured` or `not-captured`), the `hashpath` AO-Core assigned to
the response, the `verification-input` messages, and `verification-status`
(`verified`, `failed`, `not-captured` or `unavailable`). The node computes
`verification-status` with the same comparison as `verify-hashpath`.

## `verify-hashpath`

Send the receipt's `ao-core` object as `ao-core`. A whole receipt under
`receipt`, or `verification-input` (`base`, `request`, `response`, optional
`rest`) and `verification-input-term` at the top level, are also accepted.

The device recomputes the HashPath from `base` and `request` and compares it
with the HashPath the receipt recorded: `ao-core.hashpath`, and the
response's private `priv.hashpath` when the transcript arrives as
`verification-input-term`. HTTP requests cannot carry private keys, so a JSON
`verification-input` sent without `ao-core.hashpath` has nothing to compare
against. Every recorded value present must match.

Returns 200 with `verified`, `expected-hashpath` (the recorded value),
`hashpath-sources` and `recomputed-hashpath`. When `verified=false`, `reason`
is `hashpath-mismatch`, `hashpath-chain-mismatch` (a `rest` step failed) or
`hashpath-not-captured`.

`hashpath-not-captured` means the input records no HashPath. This applies to
receipts with `ao-core.status=not-captured` (for example, those issued by
HyperBEAM 2c03978a). Such receipts cannot be HashPath-verified, and no
`expected-hashpath` is returned; `recomputed-hashpath` is informational.

Returns 422 with `error=invalid-hashpath-transcript` when the transcript
cannot be parsed, or `error=hashpath-verification-input-missing` when no
transcript is supplied.

AO-Core rejects posted messages whose nested `device` keys the node cannot
load before this device runs. For example, an older receipt's
`cpu-tee.device=/dev/sev-guest` causes this. Post the `ao-core` object rather
than the whole receipt.

## `publish`

Send a receipt in `receipt` or `body`. Returns 200 with the ANS-104 `id`,
`bundle-id` and `bundle-status=complete`, or 502 with
`error=receipt-publish-incomplete`. Requires `receipt-wallet-location` or the
node wallet, and a configured bundler.

## Public gateway behaviour

On `https://hb.apus.network`, the APUS explorer proxy uploads every
successful `.../completions` receipt to Arweave and adds `load_dataitem_id`
to the response. Running a completion recipe through the gateway therefore
creates an Arweave data item.
