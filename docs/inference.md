# inference@1.0

`inference@1.0` exposes an OpenAI-compatible inference interface for local or remote LLM backends.

## Exports

- `completions`
- `chat`
- `models`
- `health`
- `v1`

## Backend Routing

The device relays requests through `relay@1.0`.

- `agent-api-peer`: backend base URL, default `http://localhost:30001`.
- `agent-api-path`: backend path, defaults to `/v1/chat/completions`.
- `agent-api-key`: optional bearer token.

The default backend is a separately managed llama.cpp server. The `models`
response uses `inference-opts/model_name`, defaulting to
`MiniCPM5-2B-Q4_K_M.gguf`. Configure it to match the serving model.

## TEE Attestation

Set `tee=true` on a non-streaming request to include `sev_gpu@1.0` attestation data in the response body.

`sev_gpu@1.0` loads its native resources from the Forge implementation archive.
If the NIF is unavailable, it can use `/usr/bin/nvattest` to generate NVIDIA
attestation claims and evidence. GPU inventory remains available without TEE.

## Inference Receipts

Use `inference_receipt@1.0/v1/chat/completions` to wrap the inference call.
The device hashes the original request and response, collects
`gpu_inventory@1.0/report` and `inference_measurement@1.0/fresh`, and includes
the signed receipt in the response JSON. Streaming is rejected by this device.

The measurement adapter composes the upstream `measurement@1.0` protocol.
It preserves the `system@1.0/all` and `meta@1.0/info` subject and binds the
request digest and GPU inventory digest through the fresh measurement nonce.
The receipt retains the system report, GPU inventory, and available CPU/GPU
evidence. An observation-only result remains usable when hardware measurement
is unavailable.

Execution metadata can be supplied in the request or node options:

- `model-sha256`, `model-source`, `model-tx`;
- `runtime-build-hash`, `inference-profile`.

`workload-manifest-id` is read from the request. These fields have no built-in
deployment hashes or transaction IDs. They are recorded declarations for a
verifier to compare with the actual loaded artifacts; the device does not
download or hash the serving model itself. A requested model name or supplied
hash alone does not establish which model executed.

## HashPath Verification

`inference_receipt@1.0/verify-hashpath` accepts the recorded
`verification-input` messages (`base`, `request`, `response`, and optional
`rest`), or the receipt's `verification-input-term` snapshot. It delegates to
`hb_path:verify_hashpath/2`. A different base or request fails the check;
matching only the request ID is insufficient. Invalid transcripts return
status 422 with `verified=false`.

HashPath verification checks the recorded execution-history commitment. Model
execution and hardware evidence require their respective checks.

## Receipt Publishing

Submit a completed receipt in the `receipt` or `body` field to
`inference_receipt@1.0/publish`. The device signs an ANS-104 data item with
`ans104@1.0` and submits it to `bundler@1.0/item` using the node's configured
wallet and bundler. It returns the item ID so the caller can index the receipt.
The returned ID indicates submission; gateway availability and confirmation
must be checked separately.
