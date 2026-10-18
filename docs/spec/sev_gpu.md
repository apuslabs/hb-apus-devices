# `sev_gpu@1.0` — NVIDIA confidential-computing GPU attestation

- **Depends-on:** `none`
- **Status:** Stable
- **Maintainer:** Apus Network (https://apus.network)

## 1. Overview

`sev_gpu@1.0` turns the NVIDIA GPUs of a HyperBEAM node into an attestation
source for AO-Core. Given a nonce chosen by the caller, it collects GPU
attestation evidence from every confidential-computing GPU on the host (NVIDIA
Hopper class and later, such as the H100), verifies that evidence locally with
NVIDIA's attestation SDK (NVAT), and returns the evidence, NVAT's claims and
detached Entity Attestation Token (EAT), and a single `verified` verdict.

`verified` is true only when NVAT accepts the evidence **and** the device's
own claims rule (§5.4) holds for every GPU: the attestation report was parsed,
its signature and certificate chain check out, its nonce is the caller's
nonce, and the measurements match NVIDIA's reference values.

The device is the GPU half of the Apus Network attestation chain. On the
reference deployment (https://hb.apus.network) the node runs inside an AMD
SEV-SNP guest with an H100 in confidential-computing mode;
`inference_measurement@1.0` binds `sev_gpu@1.0` evidence and the SEV-SNP host
measurement to the same 32-byte digest, and inference receipts carry the
result.

The device reaches NVAT through a native NIF (the primary backend) or, when the
NIF is not available, by running NVIDIA's `nvattest` command-line tool
directly. Both backends produce the same result shape.

## 2. Concepts & terminology

- **Nonce:** 32 bytes, written as exactly 64 hexadecimal characters (either
  letter case). The caller chooses it; NVAT embeds it in each GPU's
  attestation report. The device never supplies a nonce of its own.
- **Evidence entry:** NVAT's serialized evidence for one GPU, a JSON object
  with four strings: `arch` (GPU architecture, for example `HOPPER`), `nonce`
  (hex), `evidence` (base64 attestation report) and `certificate` (base64
  certificate chain).
- **Claim set:** NVAT's appraisal of one GPU, a JSON object of claims such as
  `measres`, `x-nvidia-gpu-attestation-report-signature-verified` and
  `eat_nonce`. The claims schema belongs to NVAT (claims version 3.0 on the
  reference deployment).
- **Detached EAT:** NVAT's token bundle: `[["JWT", <overall token>],
  {"GPU-0": <token>, ...}]`.
- **NVAT verdict:** whether NVAT's attestation call returned success
  (`NVAT_RC_OK` for the NIF, `result_code` 0 for `nvattest`). NVAT applies its
  default evidence policy and its local verifier.
- **Claims rule:** the device's additional check over the claim sets (§5.4).
- **Backend:** `nif` (the NVAT C API through the `dev_sev_gpu_nif` module) or
  `nvattest` (the NVAT command-line tool). `auto` uses the NIF when it is
  available and `nvattest` otherwise.
- **Scratch directory:** a node-configured directory where `verify` writes the
  submitted evidence to a short-lived file, because NVAT reads existing
  evidence from a file.

## 3. Device interface

**Dispatch shape:** explicit keys. `info/1` exports exactly `generate` and
`verify`; every other key falls through to `message@1.0`. Neither key reads the
base message.

| Key | Request keys | Result on success |
|---|---|---|
| `generate` | `nonce` (required) | `{ok, JSON}`: object with `nonce`, `evidences`, `claims`, `eat`, `verified` |
| `verify` | `body` or `evidences` (required); `nonce` (optional) | `{ok, <<"true">>}` or `{ok, <<"false">>}` |

**Node options.** Only the node operator chooses backends, executables,
directories and limits; no request or base message can.

| Option | Default | Meaning |
|---|---|---|
| `sev-gpu-backend` | `auto` | `auto`, `nif` or `nvattest`. Any other value fails with `invalid_backend`. |
| `sev-gpu-nvattest-path` | `/usr/bin/nvattest` | Absolute path of the `nvattest` executable. `PATH` is never searched. |
| `sev-gpu-nvattest-timeout` | `60000` | How long, in milliseconds, the device waits for one `nvattest` run: a positive integer or decimal string; other values select the default. |
| `sev-gpu-nif-timeout` | the `sev-gpu-nvattest-timeout` value | How long, in milliseconds, the device waits for one NIF call: a positive integer or decimal string; other values select the default. |
| `sev-gpu-scratch-dir` | `/tmp` | Directory for the evidence file that `verify` hands to NVAT. |

**Native assets.** The NIF backend uses these resources of the
implementation archive (the device root's `priv` directory):

```text
dev_sev_gpu_nif.beam    the dev_sev_gpu_nif module that owns the NIF
dev_sev_gpu_nif.so      the NIF, linked against libnvat
lib/libnvat.so*         optional: the NVAT shared library, when not installed on the host
```

A device loaded from its implementation archive (its module carries the
name Device Forge generates) looks for `dev_sev_gpu_nif.beam` only in the
archive's extracted resources: `dev_sev_gpu/` below its implementation
directory, then the implementation directory itself. A device compiled from
a source checkout under its source name, `dev_sev_gpu`, looks only in
`src/dev_sev_gpu/priv/` below the node's working directory. Without these
resources the `auto` backend uses `nvattest`. On first use the device loads
the module from the first match and then the library next to it. The
library's run-time search path is `$ORIGIN/lib` and `$ORIGIN/../lib`, so
`libnvat` is found without changing the node's environment. The
`dev_sev_gpu_nif` module always carries the name the library declares, so
the NIF loads whatever generated name Device Forge gives the device module.

The module and its library stay loaded for the life of the node. When a
`dev_sev_gpu_nif` module loaded from another directory is already present
(for example after the implementation archive is upgraded), the device keeps
using it and prints one line on standard error naming both files; restarting
the node loads the module and library of the current archive.

## 4. Resolved keys (normative)

### `generate` — collect and locally verify GPU evidence

- **Reads:** `nonce` from the request; the node options of §3.
- **Behaviour:**
  1. If the request has no `nonce`, fail with `nonce_required`. If `nonce` is
     not exactly 64 hexadecimal characters, fail with `invalid_nonce`. The
     device MUST NOT substitute a default nonce.
  2. Select the backend from `sev-gpu-backend` (§3).
  3. **NIF backend.** In one NIF call, collect evidence from all GPUs
     through NVML for the nonce and serialize it; then attest the GPUs for
     the same nonce with NVAT's default evidence policy and local verifier.
     The NVAT verdict is the attestation call's return code. Any other NVAT
     failure (SDK initialization, nonce parsing, evidence collection,
     serialization or context setup) fails with `nvat_error`. The
     call runs in a process of its own, and the device waits for it at most
     `sev-gpu-nif-timeout`; a call that takes longer fails with
     `nif_timeout` (§7). The NIF is not available when the `dev_sev_gpu_nif`
     module cannot be found or loaded, or when its library cannot be loaded;
     then `nif` fails with `nif_unavailable` and `auto` continues with the
     `nvattest` backend. A loaded NIF's result, `nif_timeout` included, is
     final in `auto` mode.
  4. **`nvattest` backend.** Require `sev-gpu-nvattest-path` to be an
     absolute path to an existing regular file, else fail with
     `nvattest_not_found`. Run, without a shell and with the environment
     variable `NVAT_LOG_LEVEL=off` added:

     ```text
     <nvattest> --format json attest --nonce <nonce>
     <nvattest> --format json collect-evidence --nonce <nonce>
     ```

     The device waits at most `sev-gpu-nvattest-timeout` for each run (§7),
     reads standard output only, ignores the exit status, and decodes the
     output as one non-empty JSON object. The NVAT verdict is `result_code`
     = 0 in the `attest` output; claims come from its `claims`, the detached
     EAT from its `detached_eat`, and evidence from `evidences` in the
     `collect-evidence` output.
  5. Build the result (§5.2) and set `verified` per §5.4.
- **Returns:** `{ok, JSON}` with the result object of §5.2. A negative
  attestation outcome is a successful resolution with `verified` false.

On both backends NVAT's attestation step collects its own evidence for the
same nonce, so the returned `evidences` and the `claims` come from two
collections on the same GPUs with the same nonce. A caller that needs an
appraisal of exactly the returned evidence submits it to `verify`, which
attests the submitted evidence itself.

### `verify` — re-verify serialized GPU evidence

- **Reads:** `body`, else `evidences`, from the request; optional `nonce`;
  the node options of §3.
- **Behaviour:**
  1. If neither `body` nor `evidences` is present, fail with
     `evidence_required`. A binary larger than 1 MiB (1048576 bytes) fails
     with `evidence_too_large` before it is decoded; another binary is
     decoded as JSON. The value MUST be a non-empty array of evidence
     entries (§2), or an object whose `evidences` member is one (a whole
     `generate` result qualifies); else fail with `invalid_evidence`. An
     array of more than 16 entries fails with `too_many_evidences`. Each
     entry's four fields MUST be UTF-8 strings, and the array MUST encode as
     JSON; else fail with `invalid_evidence`. An array whose compact JSON
     encoding is larger than 1 MiB fails with `evidence_too_large`.
  2. Every entry MUST carry the same nonce (letter case ignored), and that
     nonce MUST be 64 hexadecimal characters; else fail with
     `invalid_evidence`. This is the evidence nonce.
  3. If the request has a `nonce`, it MUST be 64 hexadecimal characters
     (else `invalid_nonce`). If it differs from the evidence nonce, return
     `false` without running a backend.
  4. **NIF backend.** Pass the nonce, the evidence array and the scratch
     directory to the NIF in one call. The NIF writes the evidence array to
     a fresh file in the scratch directory, attests it with NVAT's default
     evidence policy and local verifier for the evidence nonce, and removes
     the file. As in `generate`, the call is bounded by
     `sev-gpu-nif-timeout` and failures are reported the same way.
  5. **`nvattest` backend.** Write the evidence array as JSON to a new file
     `sev-gpu-evidence-<32 hex characters>.json` in the scratch directory
     (creation fails if the name exists; a write failure fails with
     `scratch_unavailable`), run

     ```text
     <nvattest> --format json attest --gpu-evidence-source file --gpu-evidence-file <file> --nonce <nonce>
     ```

     as in `generate`, and delete the file.
  6. The result is `true` exactly when the NVAT verdict is success and the
     claims rule (§5.4) holds for the claims NVAT returned, with the evidence
     nonce as the expected nonce.
- **Returns:** `{ok, <<"true">>}` or `{ok, <<"false">>}`.

## 5. Data formats & encodings

### 5.1 Nonce

64 hexadecimal characters encoding 32 bytes. Both letter cases are accepted;
the result echoes the nonce exactly as the caller sent it. Comparisons with
NVAT values (`eat_nonce`, evidence `nonce`) ignore letter case.

### 5.2 `generate` result

A compact JSON object with exactly these members:

| Member | Type | Content |
|---|---|---|
| `nonce` | string | The request nonce, as sent. |
| `evidences` | array | Evidence entries (§2), one per GPU. |
| `claims` | array | Claim sets, one per GPU. |
| `eat` | array or `null` | The detached EAT, or `null` when NVAT produced none. |
| `verified` | boolean | §5.4. |

Normalization: an NVAT value that is already an array is kept; a single
non-empty object becomes a one-element array; anything else becomes `[]`. An
`eat` that is not a non-empty array becomes `null`.

```json
{
  "nonce": "5f1c...e9a2",
  "verified": true,
  "evidences": [
    {"arch": "HOPPER", "nonce": "5f1c...e9a2", "evidence": "EeAB...", "certificate": "LS0t..."}
  ],
  "claims": [
    {
      "eat_nonce": "5f1c...e9a2",
      "measres": "success",
      "hwmodel": "GH100 A01 GSP BROM",
      "x-nvidia-gpu-arch-check": true,
      "x-nvidia-gpu-attestation-report-parsed": true,
      "x-nvidia-gpu-attestation-report-nonce-match": true,
      "x-nvidia-gpu-attestation-report-signature-verified": true,
      "x-nvidia-gpu-attestation-report-cert-chain-fwid-match": true,
      "x-nvidia-gpu-claims-version": "3.0",
      "x-nvidia-gpu-driver-version": "595.71.05"
    }
  ],
  "eat": [["JWT", "eyJhbGciOi..."], {"GPU-0": "eyJhbGciOi..."}]
}
```

### 5.3 `verify` result

The binary `true` or `false`, without JSON quoting.

### 5.4 Verification rule

For a nonce `N`, a result is verified exactly when all of the following hold:

1. The NVAT verdict is success.
2. For `generate`: `evidences` is non-empty and every entry's `nonce` equals
   `N`. (For `verify`, §4 step 2 establishes this.)
3. `claims` is non-empty, and **every** claim set (not merely one) is an
   object that satisfies:

| Claim | Required value |
|---|---|
| `measres` | `"success"` |
| `x-nvidia-gpu-arch-check` | `true` |
| `x-nvidia-gpu-attestation-report-parsed` | `true` |
| `x-nvidia-gpu-attestation-report-nonce-match` | `true` |
| `x-nvidia-gpu-attestation-report-signature-verified` | `true` |
| `x-nvidia-gpu-attestation-report-cert-chain-fwid-match` | `true` |
| `eat_nonce` | equal to `N`, letter case ignored |

A missing claim fails the rule. NVAT emits all of these claims for every GPU
it appraises (claims versions 3.0 and 4.0), so a healthy GPU passes; other
claims are returned unchanged and are not part of the rule.

### 5.5 Evidence file

The file NVAT reads in `verify` contains the evidence array as compact JSON,
the format NVAT itself serializes and accepts for file-based GPU evidence.

## 6. Ordering, freshness & caching

- Freshness comes only from the caller's nonce. Each `generate` collects new
  evidence; the device keeps no attestation state between calls and does
  not cache results, and under the node's default cache settings results
  are not stored. A caller that wants a fresh report MUST use a fresh nonce.
- `nvattest` runs `attest` before `collect-evidence`; each run has its own
  timeout. The NIF collects first and attests second, within one call and
  one timeout.
- EAT tokens carry NVAT's own issue and expiry times.
- NVAT's default policy fetches reference integrity manifests (RIMs) from
  NVIDIA's RIM service (`rim.attestation.nvidia.com`) and checks certificate
  revocation with NVIDIA's OCSP responder (`ocsp.ndis.nvidia.com`) on every
  `generate` and `verify`. The outcome therefore reflects NVIDIA's revocation
  data at call time, and both keys depend on those services being reachable.

## 7. Security & authority

- `verified` is this node's own appraisal of its own hardware. It is not proof
  to a third party. A remote verifier MUST verify the returned `evidences`
  itself (with NVAT, NVIDIA's remote attestation service, or `verify` on a node
  it trusts) and MUST check that the evidence nonce is the nonce it chose.
- Requests cannot select the backend, the `nvattest` path, the timeouts or
  the scratch directory; these are node options. Request values reach NVAT
  only as a validated hexadecimal nonce and as evidence JSON of at most 16
  entries and 1 MiB.
- `nvattest` runs from an absolute path through an argument vector, never
  through a shell. The device reads at most 16 MiB of its output and waits
  at most the configured timeout. On timeout it closes the port, which closes
  the process's standard input and output; the process ends when it next
  writes output or exits on its own. Operators who need a hard limit on the
  process lifetime point `sev-gpu-nvattest-path` at a wrapper executable that
  enforces one.
- NVAT makes its own outbound HTTPS requests (§6) through its own HTTP
  client, outside HyperBEAM's HTTP machinery. Their endpoints are NVAT's
  defaults and no request can change them; the RIM identifiers requested
  are derived from the evidence under appraisal.
- Each NIF call runs in a process of its own, and the device waits for it
  at most `sev-gpu-nif-timeout`. When the limit passes the device kills
  that process, discards its result and fails with `nif_timeout`; the NVAT
  work already under way finishes on its dirty I/O scheduler before the
  process exits.
- `verify` lets any caller start an NVAT appraisal, including the RIM and
  OCSP requests, for at most 16 evidence entries and 1 MiB of evidence per
  request. Operators that expose the device publicly MAY rate-limit
  requests to it, for example at a reverse proxy.
- Evidence files are created under unpredictable names, are never reused, and
  are deleted after each verification. They contain only the submitted
  evidence, at most 1 MiB.
- The NIF runs on dirty I/O schedulers, which the node shares with file
  I/O; each call in progress occupies one until NVAT returns. Loading the
  NIF does not change the node's environment variables.
- A device loaded from its implementation archive loads native code only
  from the archive's extracted resources (§3).
- The result is not signed by this device. Binding GPU evidence to a host
  measurement is the job of `inference_measurement@1.0`.

## 8. Errors

A failure is returned as `{error, Reply}`, where `Reply` carries the HTTP
`status`, `content-type: application/json` and a JSON body
`{"error": Code}`, with a `detail` text for the failures that have one
(`nvat_error` below). In-process callers read the same message.
Request errors are 400, `invalid_backend` is 500, and every failure of the
attestation backend is 503.

| Code | Key | Condition |
|---|---|---|
| `nonce_required` | `generate` | No `nonce` in the request. |
| `invalid_nonce` | both | `nonce` is not 64 hexadecimal characters. |
| `invalid_backend` | both | `sev-gpu-backend` is not `auto`, `nif` or `nvattest`. |
| `nif_unavailable` | both | Backend `nif` and the NIF is not available. |
| `nif_timeout` | both | A NIF call exceeded `sev-gpu-nif-timeout`. |
| `nvat_error` | both | The NIF reported a failure; `detail` is NVAT's return-code text or the NIF's description (for example an unwritable scratch directory), or `NIF call failed` when the call ended without a result. |
| `nvattest_not_found` | both | `nvattest` is needed and the configured path is not an absolute path to a regular file. |
| `nvattest_spawn_failed` | both | The executable could not be started. |
| `nvattest_timeout` | both | A run exceeded `sev-gpu-nvattest-timeout`. |
| `nvattest_invalid_response` | both | Output was not a JSON object, or exceeded 16 MiB. |
| `evidence_required` | `verify` | Neither `body` nor `evidences` is present. |
| `invalid_evidence` | `verify` | The evidence is not a non-empty, JSON-encodable array of well-formed entries (four UTF-8 string fields) with one valid nonce. |
| `too_many_evidences` | `verify` | The evidence array has more than 16 entries. |
| `evidence_too_large` | `verify` | A binary larger than 1 MiB, or an evidence array whose compact JSON encoding is larger than 1 MiB. |
| `scratch_unavailable` | `verify` | The `nvattest` backend could not write the evidence file. |

A failed attestation is not an error: `generate` returns `verified` false and
`verify` returns `false`, both with status 200.

## 9. Composition

- `inference_measurement@1.0` resolves `generate` with the hexadecimal
  binding digest of a request nonce and the GPU inventory, and embeds the
  result as `gpu-tee`.
- Inference devices request `generate` with a nonce derived from the
  exchange they attest.
- Callers resolve the device through AO-Core:

```erlang
hb_ao:resolve(
    #{ <<"device">> => <<"sev_gpu@1.0">> },
    #{ <<"path">> => <<"generate">>, <<"nonce">> => NonceHex },
    Opts
).
```

- Over HTTP: `GET /~sev_gpu@1.0/generate?nonce=<hex>`. For `verify`, `POST
  /~sev_gpu@1.0/verify` with the evidence JSON as the body and a non-JSON
  content type (it arrives as `body`), or with `content-type:
  application/json` and an object such as `{"evidences": [...], "nonce":
  "<hex>"}` (its members arrive as request keys).

## 10. Conformance (normative checklist)

1. `generate` without `nonce` fails with `nonce_required`; with a nonce that
   is not 64 hexadecimal characters it fails with `invalid_nonce`.
2. `generate` never attests a nonce the caller did not send.
3. A successful `generate` returns a JSON object with exactly `nonce`,
   `evidences`, `claims`, `eat` and `verified`, and echoes the nonce as sent.
4. `verified` is false unless the NVAT verdict is success, every evidence
   entry carries the nonce, and every claim set satisfies §5.4.
5. A claim set lacking any claim of §5.4, or with a different value, makes
   `verified` false, even when other claim sets pass.
6. `verify` returns `false` when the request `nonce` differs from the
   evidence nonce, without contacting NVAT.
7. `verify` accepts the evidence array, a whole `generate` result, or an
   `evidences` key, and rejects mixed nonces with `invalid_evidence`.
8. Backends, executable paths, timeouts and the scratch directory come only
   from node options.
9. `nvattest` is run from an absolute path without a shell, with
   `NVAT_LOG_LEVEL=off`; the device waits at most the configured timeout
   for each run.
10. The device waits at most `sev-gpu-nif-timeout` for each NIF call, and a
    call that takes longer fails with `nif_timeout`.
11. With backend `auto`, `nvattest` runs only when the NIF is not available.
12. `verify` rejects more than 16 evidence entries with
    `too_many_evidences`, and a body or evidence array larger than 1 MiB
    with `evidence_too_large`, without running a backend.
13. Evidence files written by `verify` are removed after use.
14. A device loaded from its implementation archive loads the NIF only from
    the archive's extracted resources.

## 11. Out of scope

- NVSwitch attestation and the CoRIM/EAR (`attest-v2`) workflow.
- NVIDIA's remote attestation service, relying-party policies, a local RIM
  store, and custom RIM, OCSP or evidence-policy settings: NVAT runs with its
  defaults.
- Enabling confidential-computing mode on the GPU and installing the NVIDIA
  driver, NVAT and `nvattest`.
- Validation of EAT signatures; the tokens are returned as NVAT produced them.
- Binding GPU evidence to a CPU TEE, signing results and publishing them.
