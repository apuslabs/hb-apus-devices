# Operating `inference@1.0` and `inference_receipt@1.0`

This guide covers configuration, deployment and verification. The normative
behaviour of each key is defined in the device specifications:
[`inference@1.0`](spec/inference.md) and
[`inference_receipt@1.0`](spec/inference_receipt.md).

## What the devices do

- `inference@1.0` relays OpenAI chat completions, the model list and a health
  probe to one OpenAI-compatible runtime (SGLang, vLLM, the llama.cpp server
  or any server with the same API). With `tee=true` it binds the complete
  response to a hardware attestation report.
- `inference_receipt@1.0` executes a completion as a recorded AO-Core step and
  returns a receipt signed by the node: request and response digests, the
  step's HashPath and transcript, the GPU inventory and a fresh measurement.
  It also verifies HashPaths and publishes receipts that name the node to
  Arweave.

Both devices answer with complete responses; `stream=true` is rejected.

## Configure the runtime

Only node options select the runtime. Requests cannot override them.

| Option | Default | Purpose |
|---|---|---|
| `inference-peer` | `http://localhost:30001` | Runtime origin, `scheme://host:port`. |
| `inference-path` | `/v1/chat/completions` | Chat-completions path. |
| `inference-models-path` | `/v1/models` | Model-list path. |
| `inference-health-path` | `/health` | Health path; any 2xx answer is healthy. |
| `inference-api-key` | unset | Bearer token for the runtime. |
| `inference-attestation-device` | `sev_gpu@1.0` | Device asked for a report on `tee=true`. |
| `inference-opts` | unset | Declared model and runtime facts, reported in `resolved_model`. |
| `receipt-wallet-location` | unset | Wallet file that signs published receipts; the node wallet signs them when unset. |
| `receipt-publishers` | unset | Addresses allowed to call `publish`; any caller when unset. |
| `model-sha256`, `runtime-build-hash`, `inference-profile`, `model-source`, `model-tx` | unset | Execution bindings signed into receipts; each takes precedence over a request's declaration of the same name. |

`inference-peer` is an origin, not a base URL: HyperBEAM's HTTP clients
connect to its host and port and use TLS exactly on port 443. Use
`http://host:port`, or `https://host` for TLS on port 443; a path prefix
belongs in the path options (for example
`"inference-path": "/openai/v1/chat/completions"`). A peer with a path, or
`https` on another port, makes `completions`, `models` and `health` answer
500 `runtime_misconfigured`.
Runtime calls use the node's `http-client` (default `hackney`) and its
connect and receive timeouts (`http-client-connect-timeout`,
`http-client-hackney-recv-timeout`).

An example JSON node configuration (load it with `HB_CONFIG=config.json`):

```json
{
  "inference-peer": "http://localhost:30001",
  "inference-opts": {
    "model_name": "google/gemma-4-26B-A4B-it",
    "runtime_name": "SGLang",
    "precision": "bfloat16"
  }
}
```

`inference-opts` accepts `model_name`, `model_revision`, `model_sha256`,
`runtime_name`, `runtime_version`, `runtime_build_hash`, `precision` and
`deterministic`. They are operator declarations, which the device reports
in `resolved_model` as declared. Other keys are never reported.

Start the runtime on the configured address, for example SGLang:

```bash
python3 -m sglang.launch_server --model-path google/gemma-4-26B-A4B-it \
  --host localhost --port 30001
```

Then confirm that the node reaches it:

```bash
HB=${HB:-http://localhost:8734}
curl -s -o /dev/null -w '%{http_code}\n' "$HB/~inference@1.0/health"
curl -s "$HB/~inference@1.0/v1/models"
```

`health` answers 200 while the runtime answers 2xx, and `models` returns the
runtime's own model list.

## Errors

Runtime error statuses (400-599) are passed through, with the runtime's JSON
error body and `retry-after` when present. An unreachable runtime, or one that
does not answer within the client timeouts, answers 503.
Errors produced by the device use the OpenAI error shape:

```json
{"error": {"message": "The inference runtime is unreachable.", "type": "runtime_unavailable", "code": "runtime_unavailable"}}
```

## Attested completions

Send `tee=true` (a query parameter or a JSON field). The response gains:

- `attestation`: the attestation device's report fields, plus `raw` (the JSON
  document that is attested) and `nonce`;
- `resolved_model`: the model that served the request (`model`) and the
  declared `inference-opts` facts.

`raw` records the public generation parameters, `tee`, the runtime's response
and the AO-Core execution link: the HashPath and request ID of the public
step, which holds the generation parameters and never the HTTP message. HTTP
headers, the `user` identifier and the caller's address are never recorded or
bound into that HashPath. Publishing an attestation makes `raw`, with its
prompts and completions, publicly verifiable.

To check the binding, recompute the nonce from `raw`:

```bash
HB=${HB:-http://localhost:8734}
curl -s -X POST "$HB/~inference@1.0/v1/chat/completions?tee=true" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}' \
  | python3 -c 'import hashlib,json,sys; t=sys.stdin.read(); a=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]["attestation"]; print(hashlib.sha256(a["raw"].encode()).hexdigest() == a["nonce"], a.get("verified"))'
```

`True` confirms the binding. `verified` is the node's own check of the
report; an independent verifier also checks that the report carries the same
nonce and verifies it with the hardware vendor's tooling. When the attestation
device fails, `attestation` holds only `raw` and `nonce`, which consumers must
treat as unattested.

## Receipts

`POST /~inference_receipt@1.0/v1/chat/completions` returns the runtime's JSON
with a `receipt`. Execution-profile declarations (`model-sha256`,
`runtime-build-hash`, `inference-profile`, `model-source`, `model-tx`,
`workload-manifest-id`, `model-revision`, `runtime-name`,
`runtime-version`) may be sent with the request; they are recorded as
declared. The receipt's bindings `model-sha256`, `runtime-build-hash`,
`inference-profile`, `model-source` and `model-tx` take the node option of
the same name when it is set, and the request's declaration otherwise.

`request-digest` is the SHA-256 of the executed request in a canonical JSON
encoding (compact, object keys in byte order at every depth), and
`response-digest` is the SHA-256 of the bytes of the `inference@1.0`
response body. Both are unpadded base64url and defined in the receipt
specification, so a verifier can recompute them. The receipt's
`system-measurement.envelope` is the measurement envelope exactly as
`inference_measurement@1.0` returned it; post it as `envelope` to
`/~inference_measurement@1.0/verify` to check it.

To verify a receipt's HashPath, post its `ao-core` object:

```bash
HB=${HB:-http://localhost:8734}
curl -s -X POST "$HB/~inference_receipt@1.0/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}' \
  | python3 -c 'import json,sys; t=sys.stdin.read(); r=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]["receipt"]; print(json.dumps({"ao-core": r["ao-core"]}))' \
  | curl -s -X POST "$HB/~inference_receipt@1.0/verify-hashpath" \
      -H 'content-type: application/json' -H 'accept: application/json' \
      -H 'accept-bundle: true' --data-binary @-
```

The answer's `body.verified` is `true` (the string `"true"` in the typed
HTTP encoding) when the recorded response is linked to the recorded base and
request. Hardware provenance is established by the receipt's measurement
and attestation evidence, and model identity by comparing the receipt's model
bindings with the deployed model. A `verification-input-term` whose text exceeds
1,398,102 bytes (the base64url length of 1 MiB), or that holds a compressed
term, is refused with 400 before it is decoded.

`publish` signs a document as an ANS-104 data item and submits it to the
node's bundler; it spends the publication wallet's funds. It accepts a
receipt, or a JSON object that carries one under `report.receipt`, of at most
8 MiB, whose `node-address` is this node, or a publication record whose
`attestation` is bound to its `raw` document (its `nonce` is the SHA-256 of
`raw`). The checks are structural, so a receipt stays publishable after a
client's JSON round trip; the receipt's origin is confirmed through its
`signed-receipt`, as described below. The recommended configuration
restricts `publish` to your gateway: set `receipt-publishers` to the
gateway's signing address, or refuse `/~inference_receipt@1.0/publish` to
every other caller in front of the node.
A gateway that calls `publish` on behalf of its own callers should pass it
only receipts the node returned to that gateway.
With `receipt-publishers` set, the publisher signs a message holding only
`receipt` and posts it to `/~inference_receipt@1.0/publish`; a request whose
signature also covers `path` is refused with 403, because HyperBEAM delivers
it to the device with `path: publish`.

The receipt's `signed-receipt` verifies after the JSON body is decoded: check
it with `hb_message:verify` and compare its signer with `node-address`.

## Reference deployment

Apus Network runs both devices at `https://hb.apus.network`: SGLang serves
`google/gemma-4-26B-A4B-it`, and HyperBEAM and SGLang run in one AMD SEV-SNP
guest with an NVIDIA H100 in confidential-computing mode. A gateway sits in
front of the node:

- `/~inference@1.0/*` requests without `tee=true` (a query parameter or a JSON
  field) go directly to the runtime with the `/~inference@1.0` prefix
  removed, so `/~inference@1.0/health` and `/~inference@1.0/v1/models`
  exercise the runtime, not the device. `/ao/~inference@1.0/*` requests go
  to the runtime with the `/ao/~inference@1.0` prefix removed, with or
  without `tee=true`;
- `/~inference@1.0/*` requests with `tee=true` go to `inference@1.0` on the
  node, except `/~inference@1.0/completions` with `tee=true`, which the
  gateway rewrites to `/~inference_receipt@1.0/v1/chat/completions`;
- every other request goes to the node;
- for each attested completion, the gateway publishes a public record
  through `inference_receipt@1.0/publish`: the request's chat messages and
  generation parameters, the response, the GPU attestation and, when
  present, the node's receipt under `report.receipt`. It adds
  `load_dataitem_id` and `arweave_tx_id` to the response;
- the gateway is the only caller of `publish`: it answers 403 to external
  requests for `inference_receipt@1.0/publish`, and it serves its index of
  published records (`/attestations`, `/tags/query`, `/query/dataitem`)
  read-only, checking an indexed record with `verify-hashpath` on the node.

## Tests

```bash
rebar3 device test --device-src=src,vendor/permaweb-os/src \
  --devices=dev_inference,dev_inference_receipt
```

The tests run against local HTTP stubs and a stub attestation device, so they
need neither a GPU nor a model runtime.
