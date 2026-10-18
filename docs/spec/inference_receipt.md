# `inference_receipt@1.0` — signed, HashPath-verifiable receipts for `inference@1.0` completions

- **Depends-on:** `inference@1.0` (the recorded completion step, `models`, `health`), `gpu_inventory@1.0` (`report`), `inference_measurement@1.0` (`fresh`), `bundler@1.0` (`item`, for `publish`), `ans104@1.0` (commitment device for published data items), `httpsig@1.0` (HyperBEAM's default commitment device, which commits `signed-receipt`, and default ID device, which computes the message IDs and HashPaths in `ao-core`).
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
compares it with the value the receipt recorded. `publish` signs a document
that carries a receipt naming this node in `node-address` as an ANS-104 data
item and submits it to the node's bundler, so the evidence can be stored on
Arweave.

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
- **Execution bindings:** the receipt keys `model-sha256`,
  `runtime-build-hash`, `inference-profile`, `model-source` and `model-tx`.
  Each is the operator's node option of the same name when it is set,
  otherwise the executed request's declaration (§5).
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
- **Digest:** the unpadded base64url SHA-256 of a binary's bytes, or of the
  canonical JSON encoding of any other value.
- **Canonical JSON encoding:** the encoding `request-digest` and
  `response-digest` hash, so that a verifier can recompute them:
  - compact, with no whitespace between tokens;
  - object members in ascending byte order of their UTF-8 keys, in every
    object at every depth;
  - strings as UTF-8; `"` and `\` are escaped as `\"` and `\\`, U+0008,
    U+0009, U+000A, U+000C and U+000D as `\b`, `\t`, `\n`, `\f` and `\r`,
    the other characters below U+0020 as `\u00XX` with uppercase
    hexadecimal digits, and every other character, including `/`, is written
    unescaped;
  - integers in decimal; floating-point numbers as Erlang's
    `float_to_binary(F, [short])` writes them: the shortest digits that read
    back as the same IEEE 754 double, always with a fraction or an exponent
    (`1.0`, `0.7`, `1.0e-7`, `1.2345678901234568e16`);
  - `true`, `false` and `null` as literals, and other atoms as strings.

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
| `publish` | POST | Sign a document that carries a receipt naming this node in `node-address` as an ANS-104 data item and submit it to `bundler@1.0`. |

Node options:

| Option | Default | Meaning |
|---|---|---|
| `receipt-wallet-location` | unset | Path of the wallet file that signs published data items. Unset: the node wallet signs them. |
| `receipt-publishers` | unset | List of addresses allowed to call `publish` (§4, §7). Unset: any caller. |
| `model-sha256`, `runtime-build-hash`, `inference-profile`, `model-source`, `model-tx` | unset | Execution bindings. A node option that is set takes precedence over the request's declaration of the same name (§5). |

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
     no-cache`. An `{error, _}` result is returned unchanged; any other
     result that is not `{ok, _}` is returned as `{error, Reason}`.
  4. Resolve `gpu_inventory@1.0` with `path: report`, and
     `inference_measurement@1.0` with `path: fresh` and `nonce:
     <request-digest>`; nothing else is sent. Each `{ok, Result}` is read
     with this rule:
     - a map with a `type` key is the result itself (a bare result; bare
       results MUST carry `type`, and their `body` is never unwrapped);
     - a map without `type` whose `body` is a map is that `body`;
     - a map without `type` whose `body` is a binary is that binary decoded
       as a JSON object, or `{}` when it is not one;
     - a map without `type` whose `body` is any other value is `{}`;
     - a map without `type` and without `body` is the result itself;
     - any other value is `{}`.

     A probe that returns anything but `{ok, _}`, or fails, contributes `{}`
     and the completion continues.
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
  1. Obtain the transcript. When `verification-input-term` is a binary, it
     is the transcript: an unpadded base64url Erlang external term of a map
     with the atom keys `base`, `request` and `response`. It is checked in
     this order, and the first failed check refuses the input with the 400
     error `invalid-verification-input-term` (§8), whose `reason` is shown
     in parentheses:
     1. the text is at most 1,398,102 bytes, the unpadded base64url length
        of 1 MiB, so it decodes to at most 1,048,576 bytes (`too-large`);
     2. the text is base64url (`undecodable`);
     3. the bytes are not a compressed external term, that is, version byte
        131 followed by tag 80 (`compressed`); decoding a compressed term
        allocates its uncompressed size first;
     4. the bytes decode with `binary_to_term/2` in safe mode, which creates
        no atoms (`undecodable`);
     5. the term is a map with the keys `base`, `request` and `response`
        (`undecodable`);
     6. the term contains only maps, lists, tuples, binaries, atoms and
        numbers, and so no function, process identifier, port or reference
        (`unsupported-term`).

     Otherwise the transcript is `verification-input` with `base`,
     `request`, `response` and optional `rest`, whose link objects are
     restored to AO-Core links.
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
  `recomputed-hashpath` is then informational). Unusable input returns an
  error result (§8).

### `publish` — store a receipt that names this node as an ANS-104 data item

- **Reads:** the request's `receipt`, else its `body`; the request's
  commitments; the node options `receipt-publishers` and
  `receipt-wallet-location`; the address of the node's identity wallet.
- **Behaviour:**
  1. When `receipt-publishers` is set, the request MUST carry a commitment by
     a listed address that covers the published key (`receipt` when the
     request has it, else `body`) and verifies against the request as the
     device receives it. Otherwise return the 403 error
     `receipt-publisher-not-allowed`. A value of `receipt-publishers` that is
     not a list refuses every request.
  2. Without `receipt` and `body`, return the 400 error `receipt-required`.
  3. The document is the value itself when it is a binary, otherwise the
     JSON encoding of its JSON form (§5). A document larger than 8 MiB
     (8,388,608 bytes) is refused with the 413 error `receipt-too-large`.
  4. The document MUST be a JSON object that carries a receipt: the document
     itself when its `type` is `apus-inference-receipt`, otherwise the object
     at `report.receipt` (the publication record of the reference gateway,
     §9). The receipt MUST have `type` `apus-inference-receipt`, non-empty
     strings `receipt-id`, `request-digest`, `response-digest` and
     `node-address`, and objects `ao-core` and `signed-receipt`. Otherwise
     return the 422 error `receipt-invalid`, whose `reason` is
     `not-a-json-object`, `receipt-not-found`, `invalid-type`, or
     `invalid-<key>` for the first of these keys, in this order, that is
     absent or of another type.
  5. The receipt's `node-address` MUST equal the address of the node's
     identity wallet. Otherwise return the 422 error `receipt-node-mismatch`.
  6. The device checks the structure and `node-address` only; it does not
     verify `signed-receipt`. A receipt that reaches it through a client's
     JSON round trip, such as the reference gateway's JavaScript parse and
     serialization, can carry committed values in another form: an
     integral floating-point value such as `1.0` arrives as the integer `1`,
     and an integer beyond 2^53 arrives rounded. A signature check would
     therefore refuse genuine receipts.
  7. The device commits `{data: <document>, content-type:
     application/json}` with `ans104@1.0`, signed by the publication wallet,
     resolves `bundler@1.0` with `path: item`, `await: true` and a bundle
     limit of one item, and waits until the bundle is posted. The data is
     the document's bytes, unchanged.
- **Returns:** `{ok, #{id, bundle-id, bundle-status => complete, body =>
  BundlerResponse}}` (served as HTTP 200), or the errors of §8.
- **Side effects:** signs a data item and spends the publication wallet's
  funds on its upload.

## 5. Data formats & encodings

**Receipt.** The `receipt` object has these keys; a key without a value
(for example `model` when the request names none) is omitted, in the
`receipt` message and in the JSON body alike:

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
| `model-sha256`, `runtime-build-hash`, `inference-profile`, `model-source`, `model-tx` | Execution bindings: the node option of the same name when it is set, otherwise the executed request's declaration. |
| `issued-at-unix` | Unix time in seconds. |
| `sequence` | Unix time in milliseconds. |
| `ao-core` | Execution evidence (below). |
| `device-chain` | `status` (`captured`), `receipt-device` (`inference_receipt@1.0`), `measurement-device` (`inference_measurement@1.0`), `inventory-device` (`gpu_inventory@1.0`) and `loader`, the constant `HyperBEAM Device Forge`: the toolchain that packages these devices. `loader` does not record how the node loaded the module. |
| `receipt-id` | Signed ID of `signed-receipt`. |
| `signed-receipt` | The receipt above (without `receipt-id`, `signed-receipt` and `node-address`), committed with the node's identity through the node's `commitment-device` (HyperBEAM default `httpsig@1.0`). |
| `node-address` | The address that signed `signed-receipt`; present when the commitment succeeded. |

`system-measurement` summarizes the measurement envelope that
`inference_measurement@1.0` returned and records the envelope itself. With
`composition` standing for the envelope's `apus-gpu-composition` (absent for
an observation envelope), it holds:

| Key | Value |
|---|---|
| `measurement-id` | Signed ID of the envelope. |
| `status` | `measured` when `composition.measurement-integration` is `true`, otherwise `observed`. |
| `measurement-device` | `inference_measurement@1.0`. |
| `base-measurement-device` | `measurement@1.0`, present when `status` is `measured`. |
| `measurement-integration` | `composition.measurement-integration`, else `false`. |
| `measurement-protocol` | `~measurement@1.0` when `status` is `measured`, otherwise `inference_measurement@1.0 observation-only`. |
| `provenance-class` | `composition.provenance-class`, else `host-observed`. |
| `measurement-envelope` | The envelope's `type`: `lapee-measurement` for a composed measurement, `apus-gpu-system-measurement` for an observation. |
| `subject-id` | `composition.subject-id`. |
| `nonce-binding` | `composition.nonce-binding`, else the envelope's own `nonce-binding` (an observation envelope records it at its top level). Its `request-nonce` is `request-digest`. |
| `cpu-tee` | The envelope's `cpu-tee`, else its `evidence`. |
| `gpu-tee` | The envelope's `gpu-tee`, else `{}`. |
| `system`, `node` | The keys of the same names in the envelope's `body`. |
| `evidence` | The envelope's `evidence`, else `{}`. |
| `envelope` | The envelope exactly as `inference_measurement@1.0` returned it, in the receipt's JSON form, with its commitments and every key it carries (`cpu-tee`, `gpu-tee` and, for a composed measurement, `apus-gpu-composition`). |

`cpu-tee` and `gpu-tee` are copies for convenience. The envelope verifies by
posting it as `envelope` to `/~inference_measurement@1.0/verify`; the meaning
of its fields is defined by `inference_measurement@1.0`.

`ao-core` holds:

| Key | Value |
|---|---|
| `status` | `captured` when a HashPath was recorded, else `not-captured`. |
| `hashpath` | The response's private `hashpath`, which AO-Core assigns at stage 8, else the one `inference@1.0` exposed in its response JSON (`ao-core`, or `attestation.raw` → `ao-core`). |
| `source` | The `source` of the evidence `inference@1.0` exposed, else `HyperBEAM AO-Core stage 8 (cryptographic linking, hb_path:hashpath/3)`. Both name the AO-Core stage whose function, `hb_path:hashpath/3`, computes the HashPath. |
| `hashpath-algorithm` | The recorded base message's `hashpath-alg`, which AO-Core uses to chain the HashPath, else `sha-256-chain (AO-Core default)`. The recorded base `{"device": "inference@1.0"}` names none. |
| `request-id`, `response-id` | Unsigned message IDs of the executed request and of the response. |
| `commitment-device`, `signers` | Commitment device and signers of the response (an unsigned response has none). |
| `verification-input` | The transcript: `base`, `request`, `response`. |
| `verification-input-term` | The same transcript as an uncompressed Erlang external term, unpadded base64url, which preserves private keys. Omitted when the term is larger than 1 MiB (1,048,576 bytes), the limit of `verify-hashpath`. |
| `verification-status` | `verified` or `failed` when the recomputed HashPath equals or differs from `hashpath`; `unavailable` when it cannot be recomputed; `not-captured` when nothing was recorded. |

**JSON form.** The receipt is built in its JSON form before it is committed:
absent values are removed, AO-Core links become `{"id", "type": "link",
"metadata"}` objects, other tuples, functions, process identifiers, ports and
references become their Erlang text form (`~w`), and every value is the one a
JSON decoder yields after encoding. The `receipt` message and the
receipt in the JSON body therefore carry the same values, and
`signed-receipt` taken from the decoded JSON body verifies with
`hb_message:verify` and has `node-address` as its only signer.

**`verify-hashpath` input and result.** The input is a JSON object with
`ao-core`, or with `receipt` (whose `ao-core` is used), or with
`verification-input` and `verification-input-term` at the top level. Link
objects inside `verification-input` use the JSON form above. In the HTTP
encoding of a 200 result, `verified` is typed through `ao-types`, so a JSON
client may read it as the string `"true"` or `"false"`.

**Error results.** Every error this device produces is
`{error, #{status => <code>, content-type => application/json, body =>
<JSON text>}}`, which HyperBEAM serves as that HTTP status with the JSON body
of §8. In these bodies `verified` is the JSON literal `false`.

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
  `path` and `nonce` only. Keys such as `inference-*`,
  `gpu-inventory-root` or `measurement-mode` on the request or the base
  message have no effect.
- **Bindings and declarations.** For each execution binding, a node option
  that is set takes precedence over the request's declaration, so the
  operator's value is the one signed at the top level of the receipt. A
  declaration still enters the executed request as given, and therefore the
  transcript and `request-digest`. Declarations without a node option are
  caller claims. A verifier MUST compare bindings and declarations with the
  deployed artifacts; the device does not download or hash the model.
- **Signatures.** `signed-receipt` is committed with the node's identity
  wallet; `node-address` names it. Published data items are signed by the
  publication wallet: the wallet at `receipt-wallet-location` when set, which
  keeps upload funds separate from the node's identity, otherwise the node
  wallet.
- **Publishing spends funds.** Each accepted `publish` call signs a data item
  and pays for its upload. Without `receipt-publishers`, any caller that
  reaches the key can publish a document that passes the checks of §4.
  Operators SHOULD restrict `publish` to their gateway: set
  `receipt-publishers` to the gateway's signing address, or refuse
  `/~inference_receipt@1.0/publish` to every other caller in front of the
  node. A gateway that calls `publish` on behalf of its own callers extends
  this reach to them, so it SHOULD pass `publish` only receipts that the
  node returned to that gateway.
- **What `publish` checks.** The checks of §4 establish that a document has
  the shape of a receipt and names this node in `node-address`, within 8 MiB.
  They are not a signature check: `node-address` is a public value, so a
  caller can build a document that passes them, and a publication record can
  carry fields beside its receipt. Proof that the node produced a receipt is
  `signed-receipt`, which verifies on the receipt as the node returned it
  (§5); a copy that went through a JSON round trip that changed the form of
  committed values (§4, `publish`) does not verify.
- **Publisher authority.** With `receipt-publishers` set, authority comes
  from a verified commitment by a listed address over the published key.
  HyperBEAM routes `/~inference_receipt@1.0/publish` to this key with `path:
  publish`, so a commitment that also covers `path` does not verify and is
  refused; publishers commit to the published key alone and send the signed
  message to that path. The device does not detect replays: a captured
  signed request publishes its data again, so publishers SHOULD send signed
  requests only over private or encrypted channels.
- **Posted evidence is data.** `verify-hashpath` reads posted values without
  device dispatch. The text of `verification-input-term` is bounded to
  1,398,102 bytes, the base64url length of 1 MiB, before it is decoded,
  compressed terms are refused because decoding allocates their
  uncompressed size first, the term is decoded in safe mode,
  and a term that contains a function, process identifier, port or reference
  is refused (§4).
- **What a HashPath proves.** A verified HashPath shows that the recorded
  response is linked to the recorded base and request. Hardware provenance
  and model identity require the measurement and attestation checks.

## 8. Errors

| Key | Condition | Status | Body |
|---|---|---|---|
| `completions` | `stream` truthy on the request or in its `body` | 400 | `{"error": "receipt-streaming-unsupported", "message": ...}` |
| `completions` | `inference@1.0` error | as returned | as returned (see `inference@1.0` §8) |
| `verify-hashpath` | `verification-input-term` breaks a rule of §4 | 400 | `{"verified": false, "error": "invalid-verification-input-term", "reason": <rule>}`, where `<rule>` is `too-large`, `compressed`, `undecodable` or `unsupported-term` |
| `verify-hashpath` | transcript recomputation fails | 422 | `{"verified": false, "error": "invalid-hashpath-transcript"}` |
| `verify-hashpath` | no transcript | 422 | `{"verified": false, "error": "hashpath-verification-input-missing", "reason": ...}` |
| `publish` | `receipt-publishers` set and no verified commitment by a listed address over the published key | 403 | `{"error": "receipt-publisher-not-allowed"}` |
| `publish` | no `receipt` or `body` | 400 | `{"error": "receipt-required"}` |
| `publish` | document larger than 8 MiB | 413 | `{"error": "receipt-too-large", "limit": 8388608}` |
| `publish` | document carries no receipt with the required keys (§4) | 422 | `{"error": "receipt-invalid", "reason": ...}` |
| `publish` | the receipt's `node-address` is not this node | 422 | `{"error": "receipt-node-mismatch"}` |
| `publish` | bundle not complete | 502 | `{"error": "receipt-publish-incomplete"}` |
| `publish` | bundler error or failure | 502 | `{"error": "receipt-publish-failed", "reason": ...}` (`reason` omitted when it has no JSON encoding) |

- Every row except the `inference@1.0` error is an error result of §5 with
  `content-type: application/json` and the body shown.
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
  transcript's request with the canonical JSON encoding of §2, checks the
  HashPath with `verify-hashpath`, verifies `signed-receipt` (as decoded from
  the JSON body) and compares its signer with `node-address`, posts
  `system-measurement.envelope` as `envelope` to
  `/~inference_measurement@1.0/verify`, and checks the `inference@1.0`
  attestation with that device's rules.
- **Public gateway (informative).** On the reference deployment a gateway
  sits in front of the node:
  - `/~inference@1.0/*` requests without `tee=true` (a query parameter or a
    JSON field) go directly to the runtime with the `/~inference@1.0` prefix
    removed, and `/ao/~inference@1.0/*` requests go to the runtime with the
    `/ao/~inference@1.0` prefix removed, with or without `tee=true`;
  - `/~inference@1.0/*` requests with `tee=true` go to `inference@1.0` on the
    node, except `/~inference@1.0/completions` with `tee=true`, which the
    gateway rewrites to `/~inference_receipt@1.0/v1/chat/completions`: a
    chat request whose user message is the request's `prompt`, with its
    `model`, `max_tokens` and `temperature`, `tee: true` and the
    deployment's declarations;
  - the gateway handles `GET /health`, `GET /attestations`,
    `POST /attestations`, `GET /attestations/:id`,
    `POST /attestations/:id/verify-hashpath`, `POST /tags/query` and
    `POST /query/dataitem` itself: they read its index of published
    records, check an indexed record with `verify-hashpath` on the node, or
    (`POST /attestations`) publish the posted record as described below;
  - it answers 403 to any other request whose percent-decoded URL contains
    `inference_receipt@1.0/publish`, and sends every other request,
    including this device's `health`, `models` and `completions`, to the
    node;
  - for each 200, non-streaming response from the node to a request whose
    path contains `completions`, the gateway publishes a record and adds
    `load_dataitem_id` and `arweave_tx_id` to the response, or adds
    `receipt_upload` with `status: failed` when publication does not
    succeed. To publish, it requires the response's `attestation.raw`,
    builds a publication record that carries the response's receipt, as the
    gateway normalizes it, under `report.receipt`, checks that the record
    holds no client metadata, and posts `{"receipt": <publication record as
    JSON text>}` to `publish`; each accepted record creates an Arweave data
    item. A record without a receipt that passes the checks of §4, such as
    that of an attested completion served by `inference@1.0` alone, is
    refused by `publish`;
  - `POST /attestations` posts the record in its body to `publish` after
    the same client-metadata check, so a posted record is published when it
    passes the checks of §4 (§7).

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
6. `request-digest` is the digest of the executed request in the canonical
   JSON encoding of §2, and the measurement is requested with that digest as
   its nonce.
7. The receipt has the keys of §5 and no others, is committed in its JSON
   form with the node's identity, `node-address` is the committing address,
   and `signed-receipt` decoded from the JSON body verifies.
8. Each execution binding is the node option when set, otherwise the
   request's declaration.
9. `system-measurement.envelope` is the measurement envelope exactly as
   `inference_measurement@1.0` returned it, and `nonce-binding` is the
   composition's, else the envelope's top-level one.
10. The response's `body` carries the runtime's JSON with `receipt` added.
11. `verify-hashpath` reports `verified: true` exactly when every recorded
    HashPath equals the one recomputed from `base` and `request` (and the
    chain check holds when `rest` is given). It refuses with 400 a
    `verification-input-term` that breaks a check of §4, never decodes more
    than 1 MiB or a compressed term, and answers 422 for other unusable
    input.
12. `publish` signs an ANS-104 item with the publication wallet, waits for
    the bundle and returns the item `id` at the top level; with
    `receipt-publishers` set, it first refuses with 403 any request without
    a verified commitment by a listed address over the published key; it
    publishes only documents of at most 8 MiB that carry a receipt with the
    keys of §4 whose `node-address` is this node.
13. Error results carry `content-type: application/json` and the JSON bodies
    of §8.
14. `models` and `health` return the `inference@1.0` result unchanged and
    create no receipt.

## 11. Out of scope

- Model and runtime behaviour, and the content of `inference@1.0` responses.
- Streaming completions.
- The format and verification of measurement envelopes and attestation
  reports, defined by their devices.
- Checking declarations against deployed artifacts.
- Indexing, serving and querying published receipts.
- Authentication and rate limiting of callers, beyond the
  `receipt-publishers` check of `publish`.
