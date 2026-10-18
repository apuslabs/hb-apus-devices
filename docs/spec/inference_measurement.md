# `inference_measurement@1.0` — GPU-aware system measurement

- **Depends-on:** `gpu_inventory@1.0` (default inventory device: `report`, `snapshot`), `sev_gpu@1.0` (default GPU TEE device: `generate`, `verify`), `measurement@1.0` (default base measurement device: `info`, `boot`, `fresh`, `verify`), `message@1.0` (signers, commitments, verification and IDs of envelopes), `httpsig@1.0` (the node's default commitment device: it signs observation envelopes and verifies their signatures), `json@1.0` (decoding an envelope posted to `verify` as JSON)
- **Status:** Stable
- **Maintainer:** Apus Network (https://apus.network)

## 1. Overview

`inference_measurement@1.0` produces one envelope that ties together what an
inference node is made of: the host's hardware-rooted measurement, the NVIDIA
GPU attestation, and the GPU inventory. It is the composition point of the
Apus Network attestation chain.

For each request it derives a 32-byte **binding digest** from the caller's
nonce and the GPU inventory digest. That digest is the nonce of a fresh host
measurement from `measurement@1.0` (an AMD SEV-SNP report on the reference
deployment, https://hb.apus.network) and, hex-encoded, the nonce of a fresh
NVIDIA GPU attestation from `sev_gpu@1.0`. Both hardware reports therefore
commit to the same request and the same hardware inventory. A verifier
recomputes the digest from the recorded binding, has the base measurement
device verify the host report against it, and compares it with the GPU
evidence nonce; `verify` performs exactly these checks.

On a node without a working host measurement device the device returns a
node-signed **observation** envelope: the same inventory, GPU evidence and
binding, labelled `host-observed` and never presented as a hardware
measurement.

## 2. Concepts & terminology

- **Request nonce:** the caller's freshness value (any non-empty UTF-8 text
  up to 1024 bytes); 32 random bytes, base64url-encoded, when the caller
  sends none. `inference_receipt@1.0` sends the digest of the request it
  attests.
- **Nonce binding:** the object `{"gpu-inventory-digest": <digest>,
  "request-nonce": <request nonce>}`.
- **Binding digest `D`:** SHA-256 of the nonce binding's canonical JSON (§5.1).
- **Base measurement:** an envelope of type `lapee-measurement` produced and
  signed by the base measurement device; its `body` is the measured subject
  and its `evidence` the hardware report.
- **Composed envelope:** a base measurement with `cpu-tee`, `gpu-tee` and
  `apus-gpu-composition` added by this device.
- **Hardware-bound binding:** a composed envelope whose host report commits
  to `D`: the base measurement was taken with nonce base64url(`D`) and its
  evidence carries that nonce. `fresh` compositions are hardware-bound;
  `boot` compositions are not, because the cached boot report was taken
  before the request existed.
- **Observation envelope:** an envelope of type
  `apus-gpu-system-measurement` built and signed by this node.
- **Provenance classes:**

| Class | Meaning |
|---|---|
| `host-observed` | Read from the host and signed by the node; a compromised host can forge it. |
| `host-measured-subject` | The measured subject (the base envelope's `body`) is covered by a hardware-rooted host report that the base device signs and verifies. Whether that report also commits to `D` is stated separately by `nonce-binding-hardware-bound`. |
| `runtime-observed` | Volatile values read at request time (`snapshot`); never part of a digest or binding. |

## 3. Device interface

**Dispatch shape:** explicit keys. `info/1` exports exactly `boot`, `fresh`,
`verify` and `snapshot`; every other key falls through to `message@1.0`.

| Key | Request keys | Result on success |
|---|---|---|
| `boot` | `nonce` (optional), `measurement-mode` (optional) | composed or observation envelope |
| `fresh` | `nonce` (optional), `measurement-mode` (optional) | composed or observation envelope |
| `verify` | `envelope` or `body` (required) | verification result (§4) |
| `snapshot` | none | the inventory device's runtime snapshot |

`boot` and `fresh` also read `measurement-mode` from the base message. Results
are bare messages.

**Node options:**

| Option | Default | Meaning |
|---|---|---|
| `measurement-mode` | `auto` | Default integration mode (§4, `fresh`). |
| `inference-measurement-inventory-device` | `gpu_inventory@1.0` | Device that answers `report` and `snapshot`. |
| `inference-measurement-gpu-tee-device` | `sev_gpu@1.0` | Device that answers `generate` and `verify`. |
| `inference-measurement-base-device` | `measurement@1.0` | Device that answers `info`, `boot`, `fresh` and `verify` (`verify` with an optional `nonce`). |
| `inference-measurement-sev-guest-path` | `/dev/sev-guest` | SEV-SNP guest device checked by observation envelopes. |

The device options take a device name or a device message; other values
select the default. Requests and base messages cannot select devices or paths.

## 4. Resolved keys (normative)

### `fresh` — fresh host measurement and GPU attestation for a nonce

- **Reads:** `nonce` and `measurement-mode` from the request;
  `measurement-mode` from the base message; the node options of §3.
- **Behaviour:**
  1. Read the request nonce (§2). A `nonce` that is not non-empty UTF-8
     text of at most 1024 bytes fails with status 400 and `invalid-nonce`.
  2. Resolve `report` on the inventory device. A result whose `type` is
     `apus-gpu-inventory` (bare or under `body`) and that carries a UTF-8
     text `inventory-digest` is the inventory. Otherwise the inventory is an empty
     report (`supported` false, no devices, the digest of an empty inventory)
     whose `errors` holds the failure.
  3. Build the nonce binding and its digest `D` (§5.1).
  4. Select the mode: the request's `measurement-mode`, else the base
     message's, else the node option. `observation-only` builds an
     observation envelope; `hook-body` attempts a composed envelope; any other
     value is `auto`, which attempts a composed envelope when `info` resolves
     on the base device and builds an observation envelope otherwise.
  5. **Composed envelope.** Resolve `fresh` on the base device with `nonce` =
     base64url(`D`). If the result (bare or under `body`) has `type`
     `lapee-measurement`, add to it:
     - `cpu-tee`: `type` (`amd-sev-snp` when the envelope's
       `measurement-device` is `snp@1.0`, otherwise that device name, or
       `unknown` when absent),
       `available` (the envelope's `evidence` is a non-empty object),
       `report-generated` (the evidence has `report-raw`), `verified` (the
       base device's `verify` of the envelope, with `nonce` =
       base64url(`D`), returned `verified` true), `verification` (that
       result) and `report` (the evidence);
     - `gpu-tee`: §5.2;
     - `apus-gpu-composition`: §5.3, with `integration-mode`
       `measurement-nonce` and `nonce-binding-hardware-bound` true exactly
       when the envelope's `evidence.nonce` equals base64url(`D`).
     Any other result, or an error, yields an observation envelope whose
     `failure` records it.
  6. **Observation envelope.** Build the object of §5.4 and commit it with the
     node's commitment device and key. If committing fails, the envelope is
     returned unsigned.
- **Returns:** `{ok, Envelope}`.

### `boot` — cached host measurement with fresh GPU attestation

As `fresh`, except that step 5 resolves `boot` on the base device without a
nonce: the base device returns its cached boot measurement, which does not
commit to `D`. `cpu-tee.verified` comes from the base device's `verify`
without a nonce. The GPU evidence is fresh and bound to `D`;
`integration-mode` is `boot-measurement` and `nonce-binding-hardware-bound`
is false, because nothing in the host report links it to `D`. Observation
envelopes have `purpose` `boot`.

### `verify` — check an envelope

- **Reads:** `envelope`, else `body`, from the request.
- **Behaviour:**
  1. A message is used as given. A binary is decoded with the `json@1.0`
     codec, which keeps commitments verifiable. Anything else, or a result
     that is not a message, fails with status 400 and `invalid-envelope`;
     no envelope fails with `envelope-required`.
  2. **`lapee-measurement`.** Remove `cpu-tee`, `gpu-tee` and
     `apus-gpu-composition`; the rest is the base envelope. Check the
     binding (§5.5) of `apus-gpu-composition` against `gpu-tee`
     (`nonce-binding-verified`).
     - If `apus-gpu-composition.integration-mode` is `measurement-nonce`,
       recompute `D` from its `nonce-binding` and resolve `verify` on the
       base device with the base envelope as `envelope` and `nonce` =
       base64url(`D`). `nonce-binding-hardware-bound` is true exactly when
       that verification returns `verified` true, the binding holds, and
       the base envelope's `evidence.nonce` equals base64url(`D`) (§5.6).
       `verified` = `nonce-binding-hardware-bound`. A `nonce-binding` that
       does not hold two UTF-8 text values yields no `D`; the base envelope
       is then verified without a nonce and `verified` is false.
     - Otherwise (including `boot-measurement`), resolve `verify` on the
       base device with the base envelope alone.
       `nonce-binding-hardware-bound` is false, and `verified` is true
       exactly when the base result's `verified` is true: it covers the
       base measurement only.

     Return `verified`, `base-verification` (the base device's result),
     `nonce-binding-verified`, `nonce-binding-hardware-bound`,
     `gpu-tee-verified` and `provenance-class` = `host-measured-subject`.
  3. **`apus-gpu-system-measurement`.** Restrict the envelope to the keys
     its commitments cover (the envelope as given when it cannot be
     restricted). Check that it has at least one signer and that the
     commitments of its signers verify over those keys
     (`signature-verified`); keys outside the commitments, such as the
     `status` an HTTP response adds, do not affect this check. Check the
     binding (§5.5) of the envelope as given against its `gpu-tee`. Return
     `verified` = both, `signature-verified`, `signers`,
     `nonce-binding-verified`, `gpu-tee-verified`, `observation-id` (the
     envelope's signed ID) and `provenance-class` = `host-observed`.
  4. `gpu-tee-verified` is true when `gpu-tee` is available, has non-empty
     `evidences` and a `nonce`, and the GPU TEE device's `verify` returns
     `true` for those evidences and that nonce. It reports a re-verification
     on this node and does not affect `verified`.
  5. Any other `type` fails with status 400 and `invalid-envelope`.
- **Returns:** `{ok, Result}`.

### `snapshot` — runtime GPU values

- **Reads:** node options only.
- **Behaviour:** resolve `snapshot` on the inventory device and return the
  result whose `type` is `apus-gpu-runtime-snapshot` (bare or under `body`).
  Any other result fails with status 502 and `invalid-snapshot`; an error is
  returned unchanged.
- **Returns:** `{ok, Snapshot}`; see `gpu_inventory@1.0`.

All dependency resolutions run with `cache-control: no-cache, no-store`, so
no dependency result is read from or written to the node's cache. The
default inventory device, `gpu_inventory@1.0`, may answer `report` with a
report whose collection finished up to `gpu-inventory-cache-ms` earlier
(five seconds by default); the report's `collected-at-unix` records when it
was collected.

## 5. Data formats & encodings

### 5.1 Binding digest

```text
binding = {"gpu-inventory-digest": <inventory digest>, "request-nonce": <request nonce>}
D       = SHA-256(compact JSON of binding, keys in this order, no whitespace)

base measurement nonce = base64url(D)     (unpadded; measurement@1.0 decodes it to the 32 bytes of D)
GPU attestation nonce  = hex(D)           (64 lower-case hex characters)
```

### 5.2 `gpu-tee`

The `generate` result of the GPU TEE device for `hex(D)`, read from a JSON
binary or a message (bare or under `body`): `nonce`, `verified`, `evidences`,
`claims` and `eat` (§5.2 of `sev_gpu@1.0`), plus `available` = true and
`device` (the configured device, when it is given by name). The echoed
nonce MUST equal `hex(D)`; otherwise, or when `generate` fails, `gpu-tee` is
`{nonce, device, available: false, verified: false, reason}`, where
`reason` is short text such as `nonce-mismatch`, `invalid-response` or the
device's error.

### 5.3 `apus-gpu-composition`

| Key | Value |
|---|---|
| `type` | `apus-gpu-system-measurement` |
| `version` | `1.0` |
| `measurement-integration` | `true` |
| `integration-mode` | `measurement-nonce` (`fresh`) or `boot-measurement` (`boot`) |
| `nonce-binding-hardware-bound` | For `measurement-nonce`: `true` when the base envelope's `evidence.nonce` equals base64url(`D`). Always `false` for `boot-measurement`. |
| `base-measurement-id` | Signed ID of the base envelope. |
| `gpu-inventory-digest` | The inventory digest. |
| `nonce-binding` | The nonce binding. |
| `subject-id` | Unsigned ID of the base envelope's `body`. |
| `provenance-class` | `host-measured-subject` |

The base envelope's own keys, including its commitments, are unchanged. The
keys this device adds are outside the base device's commitments.

### 5.4 Observation envelope

| Key | Value |
|---|---|
| `type` | `apus-gpu-system-measurement` |
| `version` | `1.0` |
| `purpose` | `boot` or `fresh` |
| `issued-at-unix` | Seconds since the Unix epoch. |
| `measurement-integration` | `false` |
| `integration-mode` | `observation-only` |
| `provenance-class` | `host-observed` |
| `cpu-tee` | `{type: "amd-sev-snp", available, verified: false, report-generated: false, reason}`, plus `device` (the configured path) when that path is a device or regular file. |
| `gpu-tee` | §5.2 |
| `gpu-inventory` | The inventory report. |
| `gpu-inventory-digest` | Its digest. |
| `nonce-binding` | The nonce binding. |
| `failure` | Present only when a composed envelope was attempted and failed: short text. |

### 5.5 Binding check

Given an object `H` (the observation envelope, or `apus-gpu-composition`) and
`gpu-tee`, the binding holds when `H.nonce-binding` has UTF-8 text
`request-nonce` and `gpu-inventory-digest`, that digest equals
`H.gpu-inventory-digest`, and, if `gpu-tee.available` is true,
`gpu-tee.nonce` (lower-cased) equals `hex(D)` recomputed from the binding.

This check alone shows only that the recorded values agree with each other.
In a composed envelope the keys it reads are outside the base device's
commitments; they gain hardware weight only through §5.6.

### 5.6 Host report anchor

For a `measurement-nonce` composition, `verify` recomputes `D` from
`apus-gpu-composition.nonce-binding` and requires both:

1. the base device's `verify` with `nonce` = base64url(`D`) returns
   `verified` true (`snp@1.0` then checks that the SEV-SNP report data
   commits to that nonce); and
2. the base envelope's `evidence.nonce`, which is inside the base
   commitments, equals base64url(`D`).

The second check keeps the anchor in place even with a base device that
ignores the `nonce` key of `verify`. Changing the recorded binding changes
`D` and fails both checks.

### 5.7 HTTP rendering

Request `accept: application/json` and `accept-bundle: true` to receive an
envelope as one JSON object with nested objects inline. Booleans are rendered
as `"true"` and `"false"`, typed through `ao-types`. The serving node adds a
top-level `status` to that object; it is outside the envelope's commitments,
and `verify` accepts the object exactly as received.

## 6. Ordering, freshness & caching

- Within one `fresh`, the inventory is read first, then `D` is derived, then
  the base measurement (composed mode) and the GPU attestation run.
- `fresh` produces new hardware evidence on every call; `boot` reuses the base
  device's cached boot measurement and adds fresh GPU evidence.
- Equal request nonces on equal hardware give equal `D`; freshness against
  replay therefore comes from the caller's nonce, which a verifier MUST choose
  itself.
- Dependency results are never read from or written to the node's cache;
  the inventory may be a report that the inventory device reuses (§4). The
  device keeps no state.

## 7. Security & authority

- A composed envelope's hardware trust comes from the base device's report and
  signature. The keys this device adds are outside the base commitments, so
  they carry weight only through `D`: for a `measurement-nonce` composition,
  `verify` recomputes `D` from the recorded binding and requires the host
  report to commit to it (§5.6). A composition record or GPU evidence for
  any other binding digest, attached to a genuine base envelope, therefore
  fails `verify`.
- A `boot-measurement` composition is not hardware-bound: its GPU evidence
  and binding are reported, but nothing ties them to the host report.
  `verify` reports `nonce-binding-hardware-bound` false, and its `verified`
  covers the base measurement only. A verifier that needs the GPU evidence
  tied to the host measurement MUST require `nonce-binding-hardware-bound`
  true, which only `fresh` envelopes provide.
- `D` shows that the host report and the GPU report were produced for the
  same request and inventory, after the request nonce was chosen. The GPU
  report identifies the GPU, not the host it is attached to, and `D` is
  computable from public values, so GPU evidence for the same `D` from
  another GPU also satisfies the binding. The inventory digest inside `D`
  records which GPUs the measured host reported.
- `verified` does not require GPU evidence: an envelope whose `gpu-tee` is
  unavailable still verifies its host measurement and binding. A verifier
  that requires GPU attestation MUST also require `gpu-tee-verified` true or
  verify the `gpu-tee` evidence itself.
- An observation envelope is host-observed only. It is signed by the node,
  never claims `host-measured-subject`, and reports a present SEV-SNP guest
  device as `available` with `verified` and `report-generated` false.
- A failed base measurement downgrades to an observation envelope with
  `failure`; it never upgrades a trust label.
- `verify` checks signatures and bindings; it does not decide whether a
  measured subject or a GPU claim set is acceptable. That policy belongs to
  the verifier.
- For an observation envelope, `signature-verified` is true when the
  commitments of all its signers verify, whoever the signers are, and
  `signers` lists them. A verifier MUST check that `signers` contains the
  address of the node it expects.
- Requests cannot select dependency devices or file paths. A request or base
  message may select `measurement-mode`, which only chooses between composing
  and observing.

## 8. Errors

| Key | Status | `error` | Condition |
|---|---|---|---|
| `boot`, `fresh` | 400 | `invalid-nonce` | `nonce` is empty, not a binary, not valid UTF-8, or longer than 1024 bytes. |
| `verify` | 400 | `envelope-required` | Neither `envelope` nor `body` is present. |
| `verify` | 400 | `invalid-envelope` | The input cannot be decoded, is not a message, or has another `type`. |
| `snapshot` | 502 | `invalid-snapshot` | The inventory device returned another result. |

Errors are `{error, #{status, content-type, body}}`: `content-type` is
`application/json` and `body` is the JSON text `{"error":"<error>"}`, so an
HTTP client receives the status and that JSON body directly. Unavailable
dependencies of `boot` and `fresh` are not errors: they appear in the
envelope (`failure`, `gpu-tee.reason`, `gpu-inventory.errors`). `snapshot`
returns the inventory device's own error unchanged.

## 9. Composition

```text
inference_receipt@1.0 --fresh(nonce = request digest)--> inference_measurement@1.0
    inference_measurement@1.0 --report-------------------> gpu_inventory@1.0
    inference_measurement@1.0 --fresh(nonce = base64url(D))--> measurement@1.0 --> snp@1.0
    inference_measurement@1.0 --verify(envelope, nonce = base64url(D))--> measurement@1.0
    inference_measurement@1.0 --generate(nonce = hex(D))--> sev_gpu@1.0
```

```erlang
{ok, Envelope} = hb_ao:resolve(
    #{ <<"device">> => <<"inference_measurement@1.0">> },
    #{ <<"path">> => <<"fresh">>, <<"nonce">> => RequestDigest },
    Opts
).
```

## 10. Conformance (normative checklist)

1. `D` is SHA-256 of the canonical JSON of the nonce binding (§5.1).
2. In a composed `fresh` envelope the base device receives `base64url(D)` and
   `gpu-tee.nonce` is `hex(D)`.
3. `gpu-tee` is marked unavailable when the GPU TEE device echoes any other
   nonce.
4. Without a working base device the result is an observation envelope with
   `measurement-integration` false and `provenance-class` `host-observed`.
5. An observation envelope is signed by the node when a commitment device and
   key are configured.
6. For an observation envelope exactly as `fresh` returned it (as a
   message, or in its `json@1.0` encoding), also with keys outside its
   commitments added (such as an HTTP `status`), `verify` returns
   `signature-verified` and `nonce-binding-verified` true; changing a signed
   key, the binding, or `gpu-tee.nonce` makes `verified` false.
7. `verify` delegates base measurements to the base device without the keys
   this device adds. For a `measurement-nonce` composition it passes `nonce`
   = base64url(`D`) recomputed from the recorded binding, and reports
   `verified` true only when the base device verifies the report for that
   nonce, the base evidence carries it, and the binding of
   `apus-gpu-composition` holds.
8. A genuine base envelope carrying a composition record, or available GPU
   evidence, for any binding digest other than the one its host report
   commits to does not verify.
9. `boot` compositions carry `nonce-binding-hardware-bound` false, and
   `verify` never reports them as hardware-bound.
10. Inventory and GPU TEE results are accepted bare or under `body`; GPU TEE
    results are accepted as JSON binaries or messages.
11. Dependency devices and the SEV-SNP guest path come only from node options.
12. Successful results are bare messages; errors carry `status`,
    `content-type: application/json` and the JSON body `{"error": ...}`.

## 11. Out of scope

- How the base device measures the host and verifies its report
  (`measurement@1.0`, `snp@1.0`).
- GPU attestation itself (`sev_gpu@1.0`) and inventory collection
  (`gpu_inventory@1.0`).
- Acceptance policy for measured subjects, GPU claims or inventories.
- Publishing envelopes and inference receipts.
