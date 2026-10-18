# `inference_receipt@1.0` — signed, HashPath-verifiable receipts for `inference@1.0` completions

- **Depends-on:** `inference@1.0` (the recorded completion step, `models`, `health`), `gpu_inventory@1.0` (`report`), `inference_measurement@1.0` (`fresh`), `bundler@1.0` (`item`, for `publish`), `ans104@1.0` (commitment device for published data items).
- **Status:** Stable
- **Maintainer:** Apus Network (https://apus.network)

## 1. Overview

`inference_receipt@1.0` turns one `inference@1.0` chat completion into
verifiable evidence. `completions` builds an allowlisted request, executes it
on `inference@1.0` as a single AO-Core step whose HashPath is always
generated, and returns the runtime's JSON with a `receipt` added. The receipt
binds:

- digests of the executed request and of the response;
- the step's AO-Core transcript (base, request, response) and HashPath;
- the node's GPU inventory and a fresh system measurement whose nonce is the
  request digest;
- the node's signature over all of the above.

`verify-hashpath` recomputes the HashPath of a recorded transcript and
compares it with the value the receipt recorded. `publish` signs a receipt
as an ANS-104 data item and submits it to the node's bundler, so the evidence
can be stored on Arweave.

**Reference deployment (informative).** Apus Network operates this device at
`https://hb.apus.network`, decorating an SGLang runtime that serves
`google/gemma-4-26B-A4B-it` inside an AMD SEV-SNP guest with an NVIDIA H100
in confidential-computing mode.

## 2. Concepts & terminology

- **Generation parameters:** the parameters `inference@1.0` relays, without
  its `user` identifier: `model`, `prompt`, `messages`, `max_tokens`,
  `max_completion_tokens`, `temperature`, `top_p`, `n`, `stream`, `stop`,
  `presence_penalty`, `frequency_penalty`, `logit_bias`, `seed`, `top_k`,
  `repetition_penalty`, `length_penalty`, `early_stopping`, `tools`,
  `tool_choice`, `response_format`, `chat_template_kwargs`,
  `reasoning_effort`.
- **Declarations:** optional caller statements about the deployed artifacts:
  `model-sha256`, `runtime-build-hash`, `inference-profile`, `model-source`,
  `model-tx`, `workload-manifest-id`, `model-revision`, `runtime-name`,
  `runtime-version`. They are recorded, not checked.
- **Execution keys:** the generation parameters, `tee`, `type` and the
  declarations. Only these keys of a caller's request can enter the executed
  request.
- **Executed request:** the AO-Core request message that runs on
  `inference@1.0` and is recorded (§4, `completions`).
- **Recorded step:** the resolution of the base message
  `{"device": "inference@1.0"}` with the executed request.
- **HashPath:** the AO-Core identifier that commits to a step's base message
  and request (`hb_path:hashpath/3`). AO-Core places it in the response's
  private `hashpath`.
- **Transcript:** the recorded step's base message, executed request and
  response.
- **Truthy:** the values `true`, `"true"`, `"1"` and `1`.
- **Digest:** the unpadded base64url SHA-256 of a binary, or of the JSON
  encoding of any other value.

## 3. Device interface

- **Dispatch shape:** explicit keys: `completions`, `chat`, `v1`, `models`,
  `health`, `verify-hashpath` and `publish`. No default handler; any other key
  resolves under `message@1.0`.
- **Routing keys:** `v1` and `chat` merge the request into the base message,
  keep this device and set `chat-mode: true`, so
  `/~inference_receipt@1.0/v1/chat/completions` and
  `/~inference_receipt@1.0/chat/completions` reach `completions`.

| Key | Method | Purpose |
|---|---|---|
| `completions` | POST | Execute an allowlisted completion on `inference@1.0` and attach a receipt. |
| `chat` | POST | Route to `completions`. |
| `v1` | POST, GET | Route the OpenAI `/v1/...` prefix to the next key. |
| `models` | GET | Return `inference@1.0/models`; no receipt. |
| `health` | GET | Return `inference@1.0/health`; no receipt. |
| `verify-hashpath` | POST | Recompute a recorded transcript's HashPath and compare it with the recorded value. |
| `publish` | POST | Sign a receipt as an ANS-104 data item and submit it to `bundler@1.0`. |

Node options:

| Option | Default | Meaning |
|---|---|---|
| `receipt-wallet-location` | unset | Path of the wallet file that signs published data items. Unset: the node wallet signs them. |
| `model-sha256`, `runtime-build-hash`, `inference-profile`, `model-source`, `model-tx` | unset | Execution bindings recorded when the request declares none (§5). |

The runtime route, the attestation device and the inventory and measurement
configuration are node options of `inference@1.0`, `gpu_inventory@1.0` and
`inference_measurement@1.0`; this device neither sets nor overrides them.

## 4. Resolved keys (normative)

### `completions` — execute and attach a receipt

- **Reads:** the request's `body` and execution keys; the node options
  above; the node identity wallet.
- **Behaviour:**
  1. Build the executed request: the execution keys found in the request's
     `body` (when it is a JSON object or a map), overridden by the execution
     keys found on the request itself, with `path: completions` and
     `request-nonce` (32 random bytes, unpadded base64url). No other key of
     the caller's request is included.
  2. If the executed request's `stream` is truthy, return the 400 error
     `receipt-streaming-unsupported` (§8).
  3. Resolve `{"device": "inference@1.0"}` with the executed request, using
     the node options plus `hashpath: update` and `cache-control: no-store,
     no-cache`. An error from this step is returned unchanged.
  4. Resolve `gpu_inventory@1.0` with `path: report`, and
     `inference_measurement@1.0` with `path: fresh` and `nonce:
     <request-digest>`. Each result is accepted bare or inside a
     `{status, body}` envelope; a failed probe contributes an empty object.
  5. Build the receipt (§5), commit it with the node's identity, and return
     the `inference@1.0` response with `body` and `data` replaced by the
     response JSON object plus `receipt` (or `{"response": <body>,
     "receipt": ...}` when the body is not a JSON object), and with a
     `receipt` key holding the receipt message. A response that is not a
     message is returned unchanged.
- **Returns:** `{ok, Response}`; `{error, Error}` from step 2 or step 3.

### `chat` — route a chat request

- **Reads:** the base message and the request.
- **Behaviour:** deep-merge the request, with `device` set to
  `inference_receipt@1.0` and `chat-mode` set to `true`, into the base
  message.
- **Returns:** `{ok, MergedMessage}`. Never errors.

### `v1` — route the OpenAI `/v1` prefix

- **Reads:** the base message and the request.
- **Behaviour:** identical to `chat`.
- **Returns:** `{ok, MergedMessage}`. Never errors.

### `models` — model list without a receipt

- **Reads:** nothing from the base message or the request.
- **Behaviour:** resolve `inference@1.0` with `path: models` and the node
  options.
- **Returns:** the `inference@1.0` result, unchanged.

### `health` — runtime health without a receipt

- **Reads:** nothing from the base message or the request.
- **Behaviour:** resolve `inference@1.0` with `path: health` and the node
  options.
- **Returns:** the `inference@1.0` result, unchanged.

### `verify-hashpath` — recompute a recorded HashPath

- **Reads:** the request and its `body` (when a map) as plain data: the
  `ao-core` object, a whole receipt under `receipt`, or the keys
  `verification-input` and `verification-input-term` directly. The recorded
  HashPath is read only from an `ao-core` object. Posted values are never
  resolved through a device.
- **Behaviour:**
  1. Obtain the transcript. When `verification-input-term` is present (an
     unpadded base64url Erlang external term with keys `base`, `request` and
     `response`, decoded in safe mode), it is the transcript, and a term that
     cannot be decoded makes the input unusable. Otherwise the transcript is
     `verification-input` with `base`, `request`, `response` and optional
     `rest`, whose link objects are restored to AO-Core links.
  2. Recompute the HashPath from `base` and `request`.
  3. Collect the recorded values: `ao-core.hashpath`, and the response's
     private `hashpath` when the transcript arrived as
     `verification-input-term` (HTTP requests cannot carry private keys).
  4. When `rest` is present, also verify the HashPath chain of
     `[request, response | rest]`.
- **Returns:** `{ok, #{status => 200, body => Result}}` where `Result` holds
  `verified`, `recomputed-hashpath` and, when a value was recorded,
  `expected-hashpath` (the first recorded value) and `hashpath-sources`
  (`ao-core.hashpath`, `response.priv.hashpath`). `verified` is `true`
  exactly when every recorded value equals the recomputed HashPath and the
  chain check (if any) holds. Otherwise `reason` is `hashpath-mismatch`,
  `hashpath-chain-mismatch` or `hashpath-not-captured` (nothing recorded;
  `recomputed-hashpath` is then informational). Unusable input returns
  `{ok, #{status => 422, body => ...}}` (§8).

### `publish` — store a receipt as an ANS-104 data item

- **Reads:** the request's `receipt`, else its `body`; the node option
  `receipt-wallet-location`.
- **Behaviour:**
  1. Without `receipt` and `body`, return the 400 error `receipt-required`.
  2. The data is the value itself when it is a binary, otherwise its JSON
     encoding. The device commits `{data, content-type: application/json}`
     with `ans104@1.0`, signed by the publication wallet.
  3. Resolve `bundler@1.0` with `path: item`, `await: true` and a bundle
     limit of one item, and wait until the bundle is posted.
- **Returns:** `{ok, #{id, bundle-id, bundle-status => complete, body =>
  BundlerResponse}}` (served as HTTP 200), or the errors of §8.
- **Side effects:** signs a data item and spends the publication wallet's
  funds on its upload.

## 5. Data formats & encodings

**Receipt.** The `receipt` object has these keys; a key without a value
(for example `model` when the request names none) is omitted:

| Key | Value |
|---|---|
| `type` | `apus-inference-receipt` |
| `version` | `1.0` |
| `request-id` | 16 random bytes, unpadded base64url. |
| `request-digest` | Digest of the executed request (including `path` and `request-nonce`). |
| `response-digest` | Digest of the `inference@1.0` response body, before the receipt is added. |
| `model` | The executed request's `model`. |
| `workload-manifest-id` | The executed request's declaration. |
| `gpu-inventory` | The `gpu_inventory@1.0` report. |
| `gpu-inventory-digest` | The report's `inventory-digest`. |
| `measurement-id` | Signed ID of the measurement envelope. |
| `system-measurement` | Measurement summary (below). |
| `provenance-class` | The measurement's provenance class; `receipt-observed` when no measurement was obtained. |
| `model-sha256`, `runtime-build-hash`, `inference-profile`, `model-source`, `model-tx` | Execution bindings: the executed request's declaration, else the node option of the same name, else (for the first three) the inventory's `model_sha256`, `runtime_build_hash` or `profile`. |
| `issued-at-unix` | Unix time in seconds. |
| `sequence` | Unix time in milliseconds. |
| `ao-core` | Execution evidence (below). |
| `device-chain` | `status` (`captured`), `receipt-device`, `measurement-device`, `inventory-device` and `loader` (`HyperBEAM Device Forge preloaded-store`). |
| `receipt-id` | Signed ID of `signed-receipt`. |
| `signed-receipt` | The receipt above (without `receipt-id`, `signed-receipt` and `node-address`), committed with the node's identity. |
| `node-address` | The address that signed `signed-receipt`; present when the commitment succeeded. |

`system-measurement` holds `measurement-id`, `status` (`measured` when the
measurement integrates `measurement@1.0`, otherwise `observed`),
`measurement-device`, `base-measurement-device`, `measurement-integration`,
`measurement-protocol`, `provenance-class`, `measurement-envelope`,
`subject-id`, `nonce-binding`, `cpu-tee`, `gpu-tee`, `system`, `node`,
`evidence` and `envelope` (the measurement envelope without `cpu-tee`,
`gpu-tee` and `apus-gpu-composition`). Their meaning is defined by
`inference_measurement@1.0`.

`ao-core` holds:

| Key | Value |
|---|---|
| `status` | `captured` when a HashPath was recorded, else `not-captured`. |
| `hashpath` | The response's private `hashpath`, else the one `inference@1.0` exposed in its response JSON (`ao-core`, or `attestation.raw` → `ao-core`). |
| `source` | Source label of that evidence; default `HyperBEAM AO-Core resolve stage 9`. |
| `hashpath-algorithm` | The response's `hashpath-alg` when present, else `sha-256-chain (AO-Core default)`. |
| `request-id`, `response-id` | Unsigned message IDs of the executed request and of the response. |
| `commitment-device`, `signers` | Commitment device and signers of the response (an unsigned response has none). |
| `verification-input` | The transcript: `base`, `request`, `response`. |
| `verification-input-term` | The same transcript as an unpadded base64url compressed Erlang external term, which preserves private keys. |
| `verification-status` | `verified` or `failed` when the recomputed HashPath equals or differs from `hashpath`; `unavailable` when it cannot be recomputed; `not-captured` when nothing was recorded. |

In the JSON body, values are made JSON-safe: absent values are omitted,
AO-Core links become `{"id", "type": "link", "metadata"}` objects, and other
tuples become strings.

**`verify-hashpath` input and result.** The input is a JSON object with
`ao-core`, or with `receipt` (whose `ao-core` is used), or with
`verification-input` and `verification-input-term` at the top level. Link
objects inside `verification-input` use the JSON form above. In the HTTP
encoding of the result, `verified` is typed through `ao-types`, so a JSON
client may read it as the string `"true"` or `"false"`.

## 6. Ordering, freshness & caching

- The recorded step runs with `hashpath: update`, so a HashPath is generated
  even when the node sets `hashpath: ignore` globally, and with
  `cache-control: no-store, no-cache`, so it is never served from or written
  to the result cache.
- `request-nonce` makes every executed request distinct: identical prompts
  never share a HashPath, a `request-digest` or an attestation nonce.
- The measurement is fresh for each receipt: its nonce is the request
  digest.
- `models` and `health` add no receipt and inherit the freshness of
  `inference@1.0`.
- `verify-hashpath` has no side effects.

## 7. Security & authority

- **Allowlist before execution.** A HashPath commits to every key of the
  request, so the executed request is built from the execution keys before
  the step runs. HTTP headers (including `cf-*`, `x-forwarded-*`,
  `x-real-ip`, `user-agent`, cookies and credentials), the `user` identifier
  and the caller's private address never enter the HashPath,
  `request-digest`, the transcript or the receipt.
- **Operator-only configuration.** The device resolves `inference@1.0` with
  the node options unchanged and probes the inventory and measurement with
  `path` and `nonce` only. Keys such as `inference-*`, `agent-api-*`,
  `gpu-inventory-root` or `measurement-mode` on the request or the base
  message have no effect.
- **Declarations are claims.** A declaration in the request takes precedence
  over the node option of the same name and is signed into the receipt as
  given. A verifier MUST compare declarations with the deployed artifacts;
  the device does not download or hash the model.
- **Signatures.** `signed-receipt` is committed with the node's identity
  wallet; `node-address` names it. Published data items are signed by the
  publication wallet: the wallet at `receipt-wallet-location` when set, which
  keeps upload funds separate from the node's identity, otherwise the node
  wallet.
- **Publishing spends funds.** The device does not authenticate callers of
  `publish`; anyone who can reach it can have the node sign and pay for a
  data item. Operators SHOULD restrict `publish` to trusted clients, for
  example at the gateway.
- **Posted evidence is data.** `verify-hashpath` reads posted values without
  device dispatch and decodes Erlang terms in safe mode.
- **What a HashPath proves.** A verified HashPath shows that the recorded
  response is linked to the recorded base and request. Hardware provenance
  and model identity require the measurement and attestation checks.

## 8. Errors

| Key | Condition | Status | Body |
|---|---|---|---|
| `completions` | `stream` truthy on the request or in its `body` | 400 | `{"error": "receipt-streaming-unsupported", "message": ...}` |
| `completions` | `inference@1.0` error | as returned | as returned (see `inference@1.0` §8) |
| `verify-hashpath` | transcript recomputation fails | 422 | `{"verified": false, "error": "invalid-hashpath-transcript"}` |
| `verify-hashpath` | no usable transcript | 422 | `{"verified": false, "error": "hashpath-verification-input-missing", "reason": ...}` |
| `publish` | no `receipt` or `body` | 400 | `{"error": "receipt-required"}` |
| `publish` | bundle not complete | 502 | `{"error": "receipt-publish-incomplete"}` |
| `publish` | bundler error or failure | 502 | `{"error": "receipt-publish-failed", "reason": ...}` |

- A HashPath mismatch is not an error: `verify-hashpath` returns 200 with
  `verified: false` and a `reason`.
- A failed inventory or measurement probe is not an error: the receipt
  records an empty object and the corresponding identifiers are omitted.
- A receipt whose nested values contain a `device` key the node cannot load
  is rejected by AO-Core before `verify-hashpath` runs; post the `ao-core`
  object instead of the whole receipt.

## 9. Composition

- **`inference@1.0`.** Supplies the completion, `tee=true` attestation,
  `models` and `health`. The generation parameters of §2 are exactly the
  parameters `inference@1.0` relays, without `user`.
- **`gpu_inventory@1.0` and `inference_measurement@1.0`.** Supply the
  inventory report and the fresh measurement bound to `request-digest`.
- **`bundler@1.0` and `ans104@1.0`.** Store published receipts on Arweave.
- **Verification workflow.** A verifier recomputes `request-digest` from the
  transcript's request, checks the HashPath with `verify-hashpath`, checks
  `signed-receipt` against `node-address`, and checks the measurement and the
  `inference@1.0` attestation with their own devices' rules.
- **Public gateway (informative).** On the reference deployment a gateway in
  front of the node publishes, through `publish`, a record of each successful
  completion that carries an attestation (`tee=true`), and adds
  `load_dataitem_id` to the response; such a run creates an Arweave data
  item. The gateway also serves `/~inference@1.0/completions?tee=true`
  through this device.

## 10. Conformance (normative checklist)

1. The device answers exactly the seven keys of §3, and `info` lists them.
2. `completions` rejects a truthy `stream`, on the request or in its `body`,
   with status 400 before executing.
3. The executed request contains only execution keys, `path` and a fresh
   `request-nonce`; keys of the request override keys of its `body`.
4. The recorded step runs on `{"device": "inference@1.0"}` with
   `hashpath: update` and `cache-control: no-store, no-cache`.
5. No key of the request or the base message changes the runtime route,
   credentials, inventory root or measurement mode.
6. `request-digest` is the digest of the executed request, and the
   measurement is requested with that digest as its nonce.
7. The receipt has the keys of §5 and no others, is committed with the
   node's identity, and `node-address` is the committing address.
8. The response's `body` carries the runtime's JSON with `receipt` added.
9. `verify-hashpath` reports `verified: true` exactly when every recorded
   HashPath equals the one recomputed from `base` and `request` (and the
   chain check holds when `rest` is given), and 422 for unusable input.
10. `publish` signs an ANS-104 item with the publication wallet, waits for
    the bundle and returns the item `id` at the top level.
11. `models` and `health` return the `inference@1.0` result unchanged and
    create no receipt.

## 11. Out of scope

- Model and runtime behaviour, and the content of `inference@1.0` responses.
- Streaming completions.
- The format and verification of measurement envelopes and attestation
  reports, defined by their devices.
- Checking declarations against deployed artifacts.
- Indexing, serving and querying published receipts.
- Authentication and rate limiting of callers.
