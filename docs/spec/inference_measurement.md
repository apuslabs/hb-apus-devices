# `inference_measurement@1.0` — GPU-aware system measurement

- **Depends-on:** `gpu_inventory@1.0`, `sev_gpu@1.0`, `measurement@1.0`, `message@1.0`
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
commit to the same request and the same hardware inventory, and a verifier
can check the link from the envelope alone.

On a node without a working host measurement device the device returns a
node-signed **observation** envelope: the same inventory, GPU evidence and
binding, labelled `host-observed` and never presented as a hardware
measurement.

## 2. Concepts & terminology

- **Request nonce:** the caller's freshness value (any non-empty binary up to
  1024 bytes); 32 random bytes, base64url-encoded, when the caller sends none.
  `inference_receipt@1.0` sends the digest of the request it attests.
- **Nonce binding:** the object `{"gpu-inventory-digest": <digest>,
  "request-nonce": <request nonce>}`.
- **Binding digest `D`:** SHA-256 of the nonce binding's canonical JSON (§5.1).
- **Base measurement:** an envelope of type `lapee-measurement` produced and
  signed by the base measurement device; its `body` is the measured subject
  and its `evidence` the hardware report.
- **Composed envelope:** a base measurement with `cpu-tee`, `gpu-tee` and
  `apus-gpu-composition` added by this device.
- **Observation envelope:** an envelope of type
  `apus-gpu-system-measurement` built and signed by this node.
- **Provenance classes:**

| Class | Meaning |
|---|---|
| `host-observed` | Read from the host and signed by the node; a compromised host can forge it. |
| `host-measured-subject` | Bound into a hardware-rooted host measurement through the binding digest. |
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
| `inference-measurement-base-device` | `measurement@1.0` | Device that answers `info`, `boot`, `fresh` and `verify`. |
| `inference-measurement-sev-guest-path` | `/dev/sev-guest` | SEV-SNP guest device checked by observation envelopes. |

The device options take a device name or a device message; other values
select the default. Requests and base messages cannot select devices or paths.

## 4. Resolved keys (normative)

### `fresh` — fresh host measurement and GPU attestation for a nonce

- **Reads:** `nonce` and `measurement-mode` from the request;
  `measurement-mode` from the base message; the node options of §3.
- **Behaviour:**
  1. Read the request nonce (§2). A `nonce` that is not a non-empty binary of
     at most 1024 bytes fails with status 400 and `invalid-nonce`.
  2. Resolve `report` on the inventory device. A result whose `type` is
     `apus-gpu-inventory` (bare or under `body`) and that carries a text
     `inventory-digest` is the inventory. Otherwise the inventory is an empty
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
       base device's `verify` of the envelope returned `verified` true),
       `verification` (that result) and `report` (the evidence);
     - `gpu-tee`: §5.2;
     - `apus-gpu-composition`: §5.3, with `integration-mode`
       `measurement-nonce`.
     Any other result, or an error, yields an observation envelope whose
     `failure` records it.
  6. **Observation envelope.** Build the object of §5.4 and commit it with the
     node's commitment device and key. If committing fails, the envelope is
     returned unsigned.
- **Returns:** `{ok, Envelope}`.

### `boot` — cached host measurement with fresh GPU attestation

As `fresh`, except that step 5 resolves `boot` on the base device without a
nonce: the base device returns its cached boot measurement, which does not
commit to `D`. The GPU evidence is fresh and bound to `D`, and
`integration-mode` is `boot-measurement`. Observation envelopes have
`purpose` `boot`.

### `verify` — check an envelope

- **Reads:** `envelope`, else `body`, from the request.
- **Behaviour:**
  1. A message is used as given. A binary is decoded with the `json@1.0`
     codec, which keeps commitments verifiable. Anything else, or a result
     that is not a message, fails with status 400 and `invalid-envelope`;
     no envelope fails with `envelope-required`.
  2. **`lapee-measurement`.** Remove `cpu-tee`, `gpu-tee` and
     `apus-gpu-composition`, and resolve `verify` on the base device with
     the remaining envelope as `envelope`. Check the binding (§5.5) of
     `apus-gpu-composition` against `gpu-tee`. Return `verified` = (the base
     result's `verified` is true) and (the binding holds),
     `base-verification`, `nonce-binding-verified`, `gpu-tee-verified` and
     `provenance-class` = `host-measured-subject`.
  3. **`apus-gpu-system-measurement`.** Check that the envelope has at least
     one signer and that the commitments of its signers verify
     (`signature-verified`), and check the binding (§5.5) of the envelope
     against its `gpu-tee`. Return `verified` = both, `signature-verified`,
     `signers`, `nonce-binding-verified`, `gpu-tee-verified`,
     `observation-id` (the envelope's signed ID) and `provenance-class` =
     `host-observed`.
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
every envelope observes the host afresh.

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
`device` (the configured device, when it is given by name). The echoed nonce MUST equal `hex(D)`;
otherwise, or when `generate` fails, `gpu-tee` is `{nonce, device,
available: false, verified: false, reason}`, where `reason` is short text
such as `nonce-mismatch`, `invalid-response` or the device's error.

### 5.3 `apus-gpu-composition`

| Key | Value |
|---|---|
| `type` | `apus-gpu-system-measurement` |
| `version` | `1.0` |
| `measurement-integration` | `true` |
| `integration-mode` | `measurement-nonce` (`fresh`) or `boot-measurement` (`boot`) |
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
`gpu-tee`, the binding holds when `H.nonce-binding` has text
`request-nonce` and `gpu-inventory-digest`, that digest equals
`H.gpu-inventory-digest`, and, if `gpu-tee.available` is true,
`gpu-tee.nonce` (lower-cased) equals `hex(D)` recomputed from the binding.

### 5.6 HTTP rendering

Request `accept: application/json` and `accept-bundle: true` to receive an
envelope as one JSON object with nested objects inline. Booleans are rendered
as `"true"` and `"false"`, typed through `ao-types`.

## 6. Ordering, freshness & caching

- Within one `fresh`, the inventory is read first, then `D` is derived, then
  the base measurement (composed mode) and the GPU attestation run.
- `fresh` produces new hardware evidence on every call; `boot` reuses the base
  device's cached boot measurement and adds fresh GPU evidence.
- Equal request nonces on equal hardware give equal `D`; freshness against
  replay therefore comes from the caller's nonce, which a verifier MUST choose
  itself.
- Dependency results are never read from or written to the cache. The device
  keeps no state.

## 7. Security & authority

- A composed envelope's hardware trust comes from the base device's report and
  signature. The binding digest links that report, the GPU report and the
  inventory: whoever knows the request nonce and the inventory digest
  recomputes `D` and checks both nonces.
- An observation envelope is host-observed only. It is signed by the node,
  never claims `host-measured-subject`, and reports a present SEV-SNP guest
  device as `available` with `verified` and `report-generated` false.
- A failed base measurement downgrades to an observation envelope with
  `failure`; it never upgrades a trust label.
- `verify` checks signatures and bindings; it does not decide whether a
  measured subject or a GPU claim set is acceptable. That policy belongs to
  the verifier.
- Requests cannot select dependency devices or file paths. A request or base
  message may select `measurement-mode`, which only chooses between composing
  and observing.

## 8. Errors

| Key | Status | `body.error` | Condition |
|---|---|---|---|
| `boot`, `fresh` | 400 | `invalid-nonce` | `nonce` is empty, not a binary, or longer than 1024 bytes. |
| `verify` | 400 | `envelope-required` | Neither `envelope` nor `body` is present. |
| `verify` | 400 | `invalid-envelope` | The input cannot be decoded, is not a message, or has another `type`. |
| `snapshot` | 502 | `invalid-snapshot` | The inventory device returned another result. |

Errors are `{error, #{status, body => #{error}}}`. Unavailable dependencies of
`boot` and `fresh` are not errors: they appear in the envelope (`failure`,
`gpu-tee.reason`, `gpu-inventory.errors`). `snapshot` returns the inventory
device's own error unchanged.

## 9. Composition

```text
inference_receipt@1.0 --fresh(nonce = request digest)--> inference_measurement@1.0
    inference_measurement@1.0 --report-------------------> gpu_inventory@1.0
    inference_measurement@1.0 --fresh(nonce = base64url(D))--> measurement@1.0 --> snp@1.0
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
   message, or in its `json@1.0` encoding), `verify` returns
   `signature-verified` and `nonce-binding-verified` true; changing a signed
   key, the binding, or `gpu-tee.nonce` makes `verified` false.
7. `verify` delegates base measurements to the base device without the keys
   this device adds, and requires the binding of `apus-gpu-composition` to
   hold.
8. Inventory and GPU TEE results are accepted bare or under `body`; GPU TEE
   results are accepted as JSON binaries or messages.
9. Dependency devices and the SEV-SNP guest path come only from node options.
10. Successful results are bare messages; errors carry `status` and
    `body.error`.

## 11. Out of scope

- How the base device measures the host and verifies its report
  (`measurement@1.0`, `snp@1.0`).
- GPU attestation itself (`sev_gpu@1.0`) and inventory collection
  (`gpu_inventory@1.0`).
- Acceptance policy for measured subjects, GPU claims or inventories.
- Publishing envelopes and inference receipts.
