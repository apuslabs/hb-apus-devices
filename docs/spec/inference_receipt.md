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
| `verify-hashpath` | POST | Recomputes the HashPath of a recorded transcript. |
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
unavailable), `verification-input` messages, and the node's signature.

## `verify-hashpath`

Send the receipt's `verification-input` (`base`, `request`, `response`,
optional `rest`) or `verification-input-term`. Returns 200 with
`verified=true|false`, `expected-hashpath` and `recomputed-hashpath`, or 422
with `error=invalid-hashpath-transcript` when the transcript cannot be parsed.

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
