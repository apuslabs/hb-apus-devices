# `inference@1.0` — OpenAI-compatible inference on an operator-configured model runtime

- **Depends-on:** `relay@1.0` (every HTTP call to the runtime), `sev_gpu@1.0` (default attestation device for `tee=true`; the operator may name another device that answers `generate`).
- **Status:** Stable
- **Maintainer:** Apus Network (https://apus.network)

## 1. Overview

`inference@1.0` exposes an OpenAI-compatible chat-completion interface on a
HyperBEAM node. It forwards each request to one model runtime chosen by the
node operator (any server that implements the OpenAI chat-completions API,
such as SGLang, vLLM or the llama.cpp server) and returns the runtime's
answer as an AO-Core message. It also returns the runtime's model list and
probes the runtime's health endpoint.

The runtime's address, request paths and credential are node options. A
request cannot change them, so a caller cannot point the node at another
server, read the operator's credential, or obtain the node's attestation for
a response the configured runtime did not produce.

With `tee=true`, the device records the public generation request, the
runtime's response and the AO-Core execution link in a JSON document called
`raw`, and asks the attestation device for a report bound to the SHA-256 of
exactly those bytes. A verifier can therefore tie a hardware report to one
request and one response.

Results are complete messages. The device does not stream: `stream=true` is
rejected (§8), because an AO-Core result is one message and both the
attestation and `inference_receipt@1.0` cover a complete response body.

**Reference deployment (informative).** Apus Network operates this device at
`https://hb.apus.network`. There, the runtime is SGLang serving
`google/gemma-4-26B-A4B-it`, and HyperBEAM and SGLang run inside one AMD
SEV-SNP guest with an NVIDIA H100 in confidential-computing mode;
`sev_gpu@1.0` produces the NVIDIA GPU attestation reports.

## 2. Concepts & terminology

- **Runtime:** the OpenAI-compatible HTTP server that performs inference. It
  is addressed by the node options in §3 and reached only through
  `relay@1.0`.
- **Runtime origin:** the `scheme://host:port` the device derives from the
  `inference-peer` node option (§3).
- **Generation parameters:** the OpenAI request fields the device relays when
  it builds the runtime payload itself: `model`, `prompt`, `messages`,
  `max_tokens`, `max_completion_tokens`, `temperature`, `top_p`, `n`,
  `stream`, `stop`, `presence_penalty`, `frequency_penalty`, `logit_bias`,
  `user`, `seed`, `top_k`, `repetition_penalty`, `length_penalty`,
  `early_stopping`, `tools`, `tool_choice`, `response_format`,
  `chat_template_kwargs`, `reasoning_effort`.
- **Public generation parameters:** the generation parameters without
  `user`. `user` identifies the caller and does not affect sampling, so it is
  never recorded.
- **Runtime payload:** the JSON document posted to the runtime (§4,
  `completions`).
- **Public request:** the public generation parameters found in the runtime
  payload, plus the request's `tee` value. It is the only request data the
  attestation records.
- **`raw`:** the JSON document that the attestation binds (§5).
- **Attestation nonce:** the lowercase hexadecimal SHA-256 of the `raw` bytes.
- **Truthy:** the values `true`, `"true"`, `"1"` and `1`.
- **HTTP-shaped result:** a message with `status` (integer), `content-type`
  and `body` (binary). HyperBEAM serves it as that HTTP response.
- **Message-shaped result:** a message with `data` and `action`, returned to
  AO process messages (requests with `type: Message`).
- **Request keys:** keys of the request message. For HTTP callers these are
  the query parameters, the headers and, for `content-type:
  application/json`, the fields of the JSON body.

## 3. Device interface

- **Dispatch shape:** explicit keys. The device answers `completions`, `chat`,
  `v1`, `models` and `health`, and installs no default handler. Any other key
  resolves under `message@1.0`.
- **Routing keys:** `v1` and `chat` merge the request into the base message
  and keep this device, so `/~inference@1.0/v1/chat/completions`,
  `/~inference@1.0/chat/completions` and `/~inference@1.0/completions` all
  reach `completions`, and `/~inference@1.0/v1/models` reaches `models`.

| Key | Method | Purpose |
|---|---|---|
| `completions` | POST | Run one chat completion on the runtime; with `tee=true`, attach an attestation. |
| `chat` | POST | Route to `completions`; marks the base message with `chat-mode: true`. |
| `v1` | POST, GET | Route the OpenAI `/v1/...` prefix to the next key. |
| `models` | GET | Return the runtime's model list. |
| `health` | GET | Probe the runtime's health endpoint. |

Node options (read with `hb_opts:get`; never from the request or the base
message):

| Option | Default | Meaning |
|---|---|---|
| `inference-peer` | `http://localhost:30001` | Origin of the runtime (rules below). |
| `inference-path` | `/v1/chat/completions` | Path for `completions`. |
| `inference-models-path` | `/v1/models` | Path for `models`. |
| `inference-health-path` | `/health` | Path for `health`. |
| `inference-api-key` | unset | Bearer token sent to the runtime when set to a non-empty binary. |
| `inference-attestation-device` | `sev_gpu@1.0` | Device resolved with `generate` and `nonce` for `tee=true`. |
| `inference-opts` | unset | Map of declared model and runtime facts reported in `resolved_model` (§5). |

**Runtime origin.** HyperBEAM's HTTP clients connect to a peer's host and
port only, and use TLS exactly when the port is 443. `inference-peer` is
therefore an origin, not a base URL:

- the scheme is `http` or `https` (any letter case);
- the port is explicit, or implied: 80 for `http`, 443 for `https`;
- `https` requires port 443, and `http` MUST NOT use port 443;
- there is no path other than `/`, no query, no fragment and no user
  information, and the host is non-empty and not an IPv6 literal.

A runtime served under a path prefix is configured through the three path
options, for example `inference-path: /openai/v1/chat/completions`. A path
without a leading `/` gets one. When `inference-peer` breaks these rules,
`completions`, `models` and `health` answer the 500 error
`runtime_misconfigured` (§8) and send nothing.

**HTTP client.** Runtime calls use the node's `http-client` option (HyperBEAM
default `hackney`) in place of `relay@1.0`'s `relay-http-client`, so the
node's HTTP client timeouts apply; for `hackney` these are
`http-client-connect-timeout` and `http-client-hackney-recv-timeout`. A
runtime that does not answer within them is reported as unreachable (503).

## 4. Resolved keys (normative)

### `completions` — run one chat completion

- **Reads:** request keys `stream`, `body`, `tee`, `type` and the generation
  parameters; node options `inference-peer`, `inference-path`,
  `inference-api-key`, `inference-attestation-device`, `inference-opts`. The
  base message is read only when `tee` is truthy, to compute the step's
  HashPath for `raw`.
- **Behaviour:**
  1. If the request's `stream` is truthy, or the request's `body` is a JSON
     object (or a map) whose `stream` is truthy, return the 400 error
     `streaming_unsupported` (§8). The runtime is not called. An unusable
     `inference-peer` is reported next, as in §3.
  2. Build the runtime payload. If the request has a binary `body`, it is the
     payload, unchanged. If `body` is a map, the payload is that map encoded
     as JSON after removing `commitments` and private keys. Otherwise the
     payload is a JSON object of the generation parameters present on the
     request.
  3. Send `POST <runtime origin><inference-path>` through `relay@1.0` with
     `content-type: application/json` and, when `inference-api-key` is set,
     `authorization: Bearer <key>`.
  4. A runtime response with status 200-299 is a success (a relay result
     without a status counts as 200). Any other status is a runtime error,
     and a failed transport is a runtime outage (§8).
  5. On success without a truthy `tee`, return the runtime's status,
     `content-type` (default `application/json`) and body.
  6. On success with a truthy `tee`, build `raw` and the attestation (§5),
     then return status (the runtime's), `content-type: application/json`
     and a body equal to the runtime's JSON object with `attestation` and
     `resolved_model` added. When the runtime's body is not a JSON object,
     the body is `{"response": <runtime body>, "attestation": ...,
     "resolved_model": ...}`.
  7. When the request's `type` is `Message`, the result is message-shaped:
     `data` carries the body and `action` is `Inference-Response` (success)
     or `Inference-Error` (error).
- **Returns:** `{ok, Result}` on success; `{error, Result}` on an error. Both
  are HTTP-shaped unless step 7 applies.

### `chat` — route a chat request

- **Reads:** the base message and the request.
- **Behaviour:** deep-merge the request, with `device` set to `inference@1.0`
  and `chat-mode` set to `true`, into the base message. `chat-mode` is a
  marker; no key of this device reads it.
- **Returns:** `{ok, MergedMessage}`. Never errors.

### `v1` — route the OpenAI `/v1` prefix

- **Reads:** the base message and the request.
- **Behaviour:** deep-merge the request, with `device` set to
  `inference@1.0`, into the base message.
- **Returns:** `{ok, MergedMessage}`. Never errors.

### `models` — return the runtime's model list

- **Reads:** node options `inference-peer`, `inference-models-path`,
  `inference-api-key`. Nothing from the base message or the request.
- **Behaviour:** send `GET <runtime origin><inference-models-path>` through
  `relay@1.0`, with `authorization` as for `completions`. The device adds,
  removes and rewrites nothing in the answer.
- **Returns:** on a 2xx answer, `{ok, Result}` with the runtime's status,
  `content-type` (default `application/json`) and body; otherwise the error
  of §8, HTTP-shaped.

### `health` — probe the runtime

- **Reads:** node options `inference-peer`, `inference-health-path`,
  `inference-api-key`. Nothing from the base message or the request.
- **Behaviour:** send `GET <runtime origin><inference-health-path>` through
  `relay@1.0`, with `authorization` as for `completions`. A 2xx answer is
  healthy.
- **Returns:** when healthy, `{ok, #{healthy => true, runtime-status =>
  <status>, checked-at => <Unix milliseconds>}}` (served as HTTP 200);
  otherwise the error of §8, HTTP-shaped.

## 5. Data formats & encodings

**`raw`** is the JSON encoding of an object with exactly these keys:

| Key | Value |
|---|---|
| `request` | The public request: the public generation parameters present in the runtime payload (when the payload is a JSON object), plus `tee` exactly as the request carried it. |
| `response` | The runtime's response message as `relay@1.0` returned it (status, response headers as keys, body), without private keys. |
| `ao-core` | The execution link of this step (below). |
| `timestamp` | Unix time in milliseconds when `raw` was built. |
| `nonce` | 32 random bytes, lowercase hexadecimal. |

`ao-core` holds:

| Key | Value |
|---|---|
| `status` | `captured` when the HashPath of this step's base message and request could be computed, otherwise `not-captured`. |
| `source` | `HyperBEAM AO-Core resolve stage 9`. |
| `hashpath` | That HashPath, when captured. |
| `hashpath-algorithm` | `sha-256-chain (AO-Core default)`. |
| `request-id`, `response-id` | Unsigned message IDs of the request and of the runtime response, private keys removed. |
| `verification-status` | `captured`. |

**Attestation.** The attestation nonce is the lowercase hexadecimal SHA-256
of the `raw` bytes (64 characters). The device resolves the attestation
device with `path: generate` and `nonce: <attestation nonce>`. The
`attestation` object is the device's result with `raw` and `nonce` added
(replacing any keys of those names):

- a binary that decodes to a JSON object contributes that object's keys;
- a map with a binary or map `body` is treated as that `body`;
- any other map contributes its own keys without `commitments`, `status`,
  `content-type` and private keys;
- an error, a failure or any other result contributes nothing, so
  `attestation` holds only `raw` and `nonce`.

For `sev_gpu@1.0` the contributed keys are the evidence fields its
specification defines (such as `evidences`, `claims`, `eat` and
`verified`).

**`resolved_model`** is an object with:

- `model`: the first non-empty string among the runtime response's `model`,
  the public request's `model` and the declared `model_name`; absent when
  none exists;
- each declared fact among `model_name`, `model_revision`, `model_sha256`,
  `runtime_name`, `runtime_version`, `runtime_build_hash`, `precision` and
  `deterministic`, taken from the `inference-opts` node option (underscore or
  hyphen spelling accepted, reported with underscores). Other keys of
  `inference-opts` are never reported.

Declared facts are operator statements; the device does not check them
against the runtime.

**Error body.** HTTP-shaped error results carry
`content-type: application/json`. Errors produced by the device have the body
`{"error": {"message": <text>, "type": <type>, "code": <code>}}`. A runtime
error whose body is a JSON object is returned with that body unchanged.

## 6. Ordering, freshness & caching

- No key is a pure function: each `completions`, `models` and `health` call
  sends a new request to the runtime.
- The runtime call and the attestation request are resolved with
  `hashpath: ignore` and `cache-control: no-store, no-cache`. They are never
  answered from, or written to, the result cache.
- Every `raw` contains a fresh `timestamp` and random `nonce`, so two
  attestations never share an attestation nonce, even for identical prompts.
- `health` reports the runtime's state at call time. Because runtime calls
  carry the node HTTP client's timeouts (§3), a runtime that accepts the
  connection and never answers is reported as unavailable once the receive
  timeout expires. A node that caches resolution results SHOULD exclude this
  device's keys.

## 7. Security & authority

- **Routing is operator-only.** The device MUST read the runtime's address,
  paths, credential and attestation device only from node options. Keys
  named `inference-*` or `agent-api-*` on the request or the base message
  have no effect. A caller therefore cannot make the node contact another
  host, nor obtain an attestation for a response from another server.
- **Credential handling.** `inference-api-key` is sent only to the runtime
  origin, as `authorization: Bearer <key>`. It is never recorded in `raw`
  and never returned. Over `http` it travels in clear text, so a runtime
  outside the node's host SHOULD be reached over `https`.
- **Published data.** `raw` records only the public request. HTTP headers
  (including `cf-*`, `x-forwarded-*`, `x-real-ip`, `user-agent`, cookies and
  credentials), the `user` identifier and the caller's private address are
  never recorded. Prompts and completions in `raw` become public when a
  client publishes the attestation.
- **What the attestation proves.** A report for the attestation nonce shows
  that the attesting hardware produced it after `raw` existed. It does not by
  itself prove where the runtime ran: that is a property of the deployment
  (in the reference deployment, HyperBEAM, the runtime and the GPU share one
  confidential guest). `verified` in the attestation is the node's own
  check. A verifier SHOULD recompute the attestation nonce from `raw`, check
  that the report carries that nonce, and verify the report with the
  hardware vendor's verifier.
- **Error detail.** Transport failures are reported without detail, because
  the underlying reason can name internal addresses; the node records the
  reason as an `inference` event.
- **Access.** The device does not authenticate callers. Anyone who can reach
  the node can use the configured runtime; capacity limits are the
  operator's responsibility.

## 8. Errors

| Condition | Status | `type` / `code` | Body |
|---|---|---|---|
| `stream` truthy on the request or in its `body` | 400 | `invalid_request_error` / `streaming_unsupported` | Device error object. |
| Runtime answers 400-599 with a JSON object | runtime status | — | The runtime's body, unchanged. |
| Runtime answers 400-599 with another body | runtime status | `runtime_error` / `runtime_error` | Device error object. |
| Runtime answers a status outside 200-299 and 400-599 | 500 | `runtime_error` / `runtime_error` | Device error object, or the runtime's JSON object. |
| Runtime unreachable, a client timeout expires, or the relay fails | 503 | `runtime_unavailable` / `runtime_unavailable` | Device error object. |
| `inference-peer` is not a supported runtime origin (§3) | 500 | `server_error` / `runtime_misconfigured` | Device error object. |

- When the runtime's error response carries `retry-after`, the HTTP-shaped
  error result carries the same `retry-after` key.
- A failed attestation is not an error: the completion succeeds and
  `attestation` holds only `raw` and `nonce`. Consumers MUST treat an
  attestation without `verified: true` and evidence as unattested.
- A non-JSON success body is not an error (§4, `completions`, step 6).

## 9. Composition

- **`relay@1.0`.** Every runtime call is a `relay@1.0` `call` with the
  runtime origin as `peer` and the configured path. The device sets the
  relay's HTTP client to the node's `http-client` (§3); the relay's other
  node options apply.
- **Attestation device.** The default `sev_gpu@1.0` answers `generate` with
  NVIDIA GPU evidence for the nonce. Any device that answers `generate` with
  a JSON object or a map can be configured instead.
- **`inference_receipt@1.0`.** Runs `completions` as a recorded AO-Core step
  with an allowlisted request and adds a signed receipt. It relies on the
  generation parameters of §2 and on `raw.ao-core`.
- **Agents.** A device that drives a model loop can resolve `completions`
  with a JSON `body` and read the result's `body`.
- **AO processes.** `completions` returns a message-shaped result to a
  request with `type: Message`.
- **Public gateway (informative).** On the reference deployment a gateway
  sits in front of the node. It sends `/~inference@1.0/*` requests without
  `tee=true` directly to the runtime, with the device prefix removed, and
  sends `tee=true` requests to HyperBEAM; for those it publishes the
  attestation record to Arweave and adds `load_dataitem_id` to the response.
  Address the node itself to exercise every key of this device.

## 10. Conformance (normative checklist)

1. The device answers exactly `completions`, `chat`, `v1`, `models` and
   `health`, and `info` lists exactly these keys.
2. The runtime's address, paths, credential and attestation device are read
   only from the node options of §3, with the stated defaults.
3. Keys named `inference-*` or `agent-api-*` on the request or the base
   message have no effect on the runtime origin, the paths, the credential
   or the attestation device.
4. `completions` rejects a truthy `stream`, on the request or in its `body`,
   with status 400 before contacting the runtime.
5. The runtime payload is the binary `body` unchanged, a map `body` without
   `commitments` and private keys, or the generation parameters present on
   the request.
6. All runtime calls go through `relay@1.0`, use the node's `http-client`,
   and go to the runtime origin; an `inference-peer` outside the rules of §3
   yields 500 `runtime_misconfigured` without any runtime call.
7. A 2xx runtime answer to `models`, or to `completions` without `tee`, is
   returned with the runtime's status, content type and body.
8. Runtime statuses 400-599 are passed through, with the runtime's JSON
   object body unchanged and `retry-after` preserved; other non-2xx statuses
   become 500; transport failures become 503.
9. `raw` has exactly the keys of §5, and its `request` contains only public
   generation parameters and `tee`.
10. The attestation device is asked for the lowercase hexadecimal SHA-256 of
    the `raw` bytes, and `attestation.nonce` equals that value.
11. A failed attestation leaves `attestation` with `raw` and `nonce` only, and
    the completion still succeeds.
12. `resolved_model` reports the served model and only the eight declared
    fact keys of §5.
13. `health` is healthy exactly when the runtime answers 2xx.
14. `completions` answers a request with `type: Message` with `data` and
    `action`.

## 11. Out of scope

- The runtime's own behaviour: model semantics, sampling, tokenization,
  tool-call formats and the fields of its responses.
- Streaming responses (server-sent events).
- Transport details of `relay@1.0` and of HyperBEAM's HTTP clients: timeout
  values, retries and connection reuse.
- The format and verification of attestation reports, defined by the
  attestation device (`sev_gpu@1.0`).
- Authentication, rate limiting and billing of callers.
- The public gateway of the reference deployment and its publishing of
  attestation records.
