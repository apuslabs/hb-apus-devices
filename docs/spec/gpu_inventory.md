# `gpu_inventory@1.0` — host-observed GPU and PCIe inventory

- **Depends-on:** `none`
- **Status:** Stable
- **Maintainer:** Apus Network (https://apus.network)

## 1. Overview

`gpu_inventory@1.0` reports which GPUs a HyperBEAM node has, as the host sees
them. It reads PCI display controllers and processing accelerators from the
node's sysfs tree, enriches NVIDIA GPUs with a predefined `nvidia-smi` query, and
commits the stable facts (identity, driver, firmware, links, topology) to a
canonical digest. Volatile values such as temperature and utilization are
reported separately and never enter the digest. Requests share collections:
an inventory report is reused for a short, configurable time (five seconds
by default), and concurrent requests wait for the collection in progress
instead of starting another `nvidia-smi` run.

The device makes no attestation claim: every value is what the host kernel
and NVIDIA's management tools report, and a compromised host can report
anything. Its role in the Apus Network attestation chain is to give each
measurement and inference receipt a stable fingerprint of the GPU hardware
it refers to; `inference_measurement@1.0` binds that fingerprint into
hardware-measured nonces.

## 2. Concepts & terminology

- **Inventoried PCI function:** a PCI function whose sysfs `class` starts
  with `0x03` (display controller, including 3D controllers such as the H100)
  or `0x12` (processing accelerator).
- **PCI address (BDF):** the sysfs name of a PCI function, such as
  `0000:01:00.0`: domain (at least four lower-case hex digits), bus, device and
  function.
- **Row:** the facts about one inventoried device.
- **Stable row:** a row without volatile fields and without unknown values.
- **Inventory digest:** base64url (unpadded) SHA-256 of the canonical JSON
  encoding of the stable rows and the topology (§5.3).
- **Provenance classes:** `host-observed` (read from the host's kernel and
  tools; spoofable by a compromised host) for `report` and `digest`, and
  `runtime-observed` (volatile values) for `snapshot`.
- **Collection:** one reading of the host that produces a report (sysfs and
  the `nvidia-smi` inventory query) or a snapshot (the `nvidia-smi` runtime
  query). Its **configuration** is the values of `gpu-inventory-root`,
  `gpu-inventory-nvidia-smi-path` and `gpu-inventory-nvidia-smi-timeout`
  in effect.

## 3. Device interface

**Dispatch shape:** explicit keys. `info/1` exports exactly `report`, `digest`
and `snapshot`; every other key falls through to `message@1.0`. No key reads
the base message or the request: a request cannot select the sysfs root or the
executable.

| Key | Result on success |
|---|---|
| `report` | `{ok, Report}`: stable rows, topology, digest, provenance and errors |
| `digest` | `{ok, Digest}`: the inventory digest alone |
| `snapshot` | `{ok, Snapshot}`: volatile per-GPU runtime values |

Results are bare data messages. No key fails: sources that cannot be read are
reported in `errors`.

**Node options:**

| Option | Default | Meaning |
|---|---|---|
| `gpu-inventory-root` | `/sys` | Root of the sysfs tree to read. |
| `gpu-inventory-nvidia-smi-path` | `nvidia-smi` | An absolute path, or a bare executable name looked up in the node's `PATH`. Any other relative path counts as absent. |
| `gpu-inventory-nvidia-smi-timeout` | `10000` | How long, in milliseconds, the device waits for one `nvidia-smi` run: a positive integer or decimal string; other values select the default. |
| `gpu-inventory-cache-ms` | `5000` | How long, in milliseconds, `report` and `digest` reuse a collected report: a non-negative integer or decimal string, where `0` disables reuse; other values select the default. |

## 4. Resolved keys (normative)

### `report` — the stable inventory

- **Reads:** node options only.
- **Behaviour:** if a report collected with the same configuration finished
  less than `gpu-inventory-cache-ms` ago, return it unchanged, including its
  `collected-at-unix` and `errors`. If a report collection with the same
  configuration is in progress, wait for it and return its report.
  Otherwise collect a new report:
  1. List `<root>/bus/pci/devices` in sorted order. If the directory does not
     exist, there are no sysfs rows and no sysfs source. Any other listing
     error adds `sysfs: unavailable (<reason>)` to `errors`.
  2. For each inventoried PCI function build a row (§5.1). A function whose
     `class` file is missing is skipped; another error reading it adds
     `<bdf>: unavailable (<reason>)` to `errors`.
  3. If the `nvidia-smi` executable exists, run it once (§5.2) with the
     inventory fields and build one NVIDIA row per output line. A missing
     executable adds no source and no error. A failed run adds the source
     `nvidia-smi` and the error `nvidia-smi: unavailable (<reason>)`.
  4. Merge each NVIDIA row into the sysfs row with the same PCI address;
     NVIDIA values replace sysfs values for shared fields. An NVIDIA row
     without a sysfs counterpart stays a row of its own.
  5. Make every row stable: remove `source`, `temperature-c`, `power-watts`,
     `utilization-gpu-percent`, `utilization-memory-percent` and
     `memory-used-mib`, then remove every field whose value is unknown (a
     nested object that becomes empty is removed too). Sort rows by PCI
     address (byte order).
  6. Compute the topology and the inventory digest (§5.3).
- **Returns:** `{ok, Report}` with:

| Key | Value |
|---|---|
| `type` | `apus-gpu-inventory` |
| `version` | `1.0` |
| `collected-at-unix` | Collection time, seconds since the Unix epoch. |
| `provenance` | `{class: "host-observed", sources: [...]}`; sources sorted, from `sysfs` and `nvidia-smi`. |
| `supported` | `true` when there is at least one row. |
| `devices` | The stable rows. |
| `topology` | §5.3. |
| `inventory-digest` | §5.3. |
| `errors` | Source errors, as text. |

### `digest` — the inventory digest

- **Reads:** node options only.
- **Behaviour:** obtain the report exactly as `report` does, reuse included,
  and return its `inventory-digest`.
- **Returns:** `{ok, #{type => apus-gpu-inventory-digest, version => 1.0,
  inventory-digest => <digest>, provenance-class => host-observed}}`.

### `snapshot` — volatile runtime values

- **Reads:** node options only.
- **Behaviour:** run `nvidia-smi` once with the runtime fields (§5.2) and build
  one row per output line, without unknown values. Errors are handled as in
  `report` step 3. sysfs is not read. A request that arrives while a
  `snapshot` collection with the same configuration is in progress waits
  for it and returns its result; a finished snapshot is never reused.
- **Returns:** `{ok, Snapshot}` with `type` = `apus-gpu-runtime-snapshot`,
  `version`, `collected-at-unix`, `provenance` = `{class: "runtime-observed",
  sources}`, `supported` (at least one row), `devices` and `errors`.

## 5. Data formats & encodings

### 5.1 Rows

A sysfs row, before stabilization (values are trimmed file contents unless
noted; a file that cannot be read gives an unknown value):

| Field | Source below `<root>/bus/pci/devices/<bdf>/` |
|---|---|
| `pci-bdf` | The directory name. |
| `class`, `vendor-id`, `device-id` | `class`, `vendor`, `device` |
| `subsystem-vendor-id`, `subsystem-device-id`, `revision` | `subsystem_vendor`, `subsystem_device`, `revision` |
| `driver` | Last component of the `driver` link target. |
| `driver-version` | `<root>/module/<driver>/version` |
| `iommu-group` | Last component of the `iommu_group` link target. |
| `pcie-link` | `{speed, width}` from `current_link_speed`, `current_link_width` |
| `drm-card` | First entry of `<root>/class/drm` (sorted) whose `device` link ends in `<bdf>`. |

An NVIDIA row:

| Field | `nvidia-smi` field |
|---|---|
| `pci-bdf` | `pci.bus_id`, normalized (§5.2) |
| `vendor-id` | always `0x10de` |
| `name`, `driver-version`, `gpu-uuid` | `name`, `driver_version`, `uuid` |
| `vram-bytes` | `memory.total` (MiB) × 1048576 |
| `compute-capability`, `vbios-version` | `compute_cap`, `vbios_version` |
| `pcie-link-gen`, `pcie-link-width` | `pcie.link.gen.current`, `pcie.link.width.current` |
| `power-limit-watts` | `power.limit` |
| `persistence-mode`, `ecc-mode`, `mig-mode` | `persistence_mode`, `ecc.mode.current`, `mig.mode.current` |

`vram-bytes` is an integer when `memory.total` is an integer.
`power-limit-watts`, and every runtime value except `name`, `pci-bdf` and
`pstate` (§5.2), is an integer when `nvidia-smi` prints an integer and the
printed text otherwise (for example `"350.00"` or `"[N/A]"`). Every other
value is text. An empty `nvidia-smi` field is unknown.

### 5.2 `nvidia-smi` invocation

The device runs the executable directly, without a shell:

```text
nvidia-smi --query-gpu=<fields> --format=csv,noheader,nounits
```

Inventory fields: `index,name,pci.bus_id,driver_version,uuid,memory.total,
compute_cap,vbios_version,pcie.link.gen.current,pcie.link.width.current,
power.limit,persistence_mode,ecc.mode.current,mig.mode.current`.

Runtime fields: `index,name,pci.bus_id,temperature.gpu,power.draw,power.limit,
utilization.gpu,utilization.memory,memory.used,memory.total,
clocks.current.graphics,clocks.current.sm,clocks.current.memory,pstate,
fan.speed`, giving `name`, `temperature-c`, `power-watts`,
`power-limit-watts`, `utilization-gpu-percent`, `utilization-memory-percent`,
`memory-used-mib`, `memory-total-mib`, `graphics-clock-mhz`, `sm-clock-mhz`,
`memory-clock-mhz`, `pstate` and `fan-speed-percent`.

The run MUST exit with status 0 within the timeout and print at most 1 MiB;
every non-empty line MUST have exactly as many comma-separated fields as were
queried. Error reasons: `timeout`, `exit-status-<n>`, `malformed-output`,
`output-too-large`, `spawn-failed`.

`nvidia-smi` prints PCI addresses with an 8-digit upper-case domain
(`00000000:3B:00.0`). The device lower-cases the address and strips leading
zeros from the domain down to four digits (`0000:3b:00.0`), the sysfs form.

### 5.3 Topology and digest

```text
topology = { "device-count": <number of rows>,
             "pci-bdfs":     <sorted PCI addresses>,
             "iommu-groups": <sorted distinct iommu-group values> }

inventory-digest = base64url(SHA-256(JSON({"devices": <stable rows>,
                                           "topology": <topology>})))
```

`JSON` is compact (no whitespace) with object keys in lexicographic byte
order at every level; base64url has no padding. Because stable rows hold only
reported values, anyone holding a `report` can recompute its digest from its
`devices` and `topology`. Every inventory with no rows has the same digest.

### 5.4 HTTP rendering

Over HTTP, request `accept: application/json` and `accept-bundle: true` to
receive the result as one JSON object with nested objects inline. Booleans are
rendered as the strings `"true"` and `"false"`, typed through `ao-types`.

## 6. Ordering, freshness & caching

- A `report` or `digest` describes the host as of the report's
  `collected-at-unix`: the report is reused for at most
  `gpu-inventory-cache-ms` after its collection finishes. Every `snapshot`
  that does not join a collection in progress reads the host afresh.
- Collections are shared through one coordinator process per node, started
  on first use and registered under the device module's name; each
  collection runs in a process of its own. The coordinator holds the
  requests waiting for each collection in progress and the most recent
  report of each configuration, which it discards on the first request
  after `gpu-inventory-cache-ms` has passed; with `gpu-inventory-cache-ms`
  `0` it keeps no report. If the coordinator or a collection process stops
  without a result, the waiting requests collect for themselves.
- Rows and topology lists are sorted, so equal hardware gives byte-identical
  canonical JSON and an equal digest, whatever order sysfs or `nvidia-smi`
  list devices in. `collected-at-unix` is outside the digest.
- The digest changes when a stable fact changes: a device is added or
  removed, a driver or VBIOS is updated, or a link width or generation
  changes.
- Results are not stored in the node's cache under its default cache
  settings.

## 7. Security & authority

- Every value is host-observed. The digest identifies what the host
  reported; it does not prove what hardware is present.
- Requests cannot choose the sysfs root, the executable, the timeout or the
  reuse time; these are node options. No key reads the request or base
  message.
- `nvidia-smi` runs through an argument vector with predefined field lists,
  never through a shell. The device reads at most 1 MiB of its output and
  waits at most the configured timeout. On timeout it closes the port, which
  closes the process's standard input and output; the process ends when it
  next writes output or exits on its own.
- While the coordinator runs (§6), for each configuration at most one
  report collection and one snapshot collection are in progress at a time,
  and a new report collection starts no earlier than
  `gpu-inventory-cache-ms` after the previous one returned its report.
  Concurrent requests therefore do not multiply `nvidia-smi` runs.
- The report contains PCI identities, driver and firmware versions and GPU
  UUIDs. It contains no credentials and no file paths.

## 8. Errors

No key returns `{error, _}`. Unreadable sources are reported as text in
`errors`, in the form `<source>: unavailable (<reason>)`, where `<source>` is
`sysfs`, `nvidia-smi` or a PCI address. A host without NVIDIA tooling reports
no `nvidia-smi` error.

## 9. Composition

- `inference_measurement@1.0` resolves `report` and binds `inventory-digest`
  into the nonces of the host measurement and the GPU attestation; it
  resolves `snapshot` for its own `snapshot` key.
- Inference receipts record `inventory-digest` to identify the hardware that
  served a request.

```erlang
{ok, Report} = hb_ao:resolve(
    #{ <<"device">> => <<"gpu_inventory@1.0">> },
    #{ <<"path">> => <<"report">> },
    Opts
).
```

## 10. Conformance (normative checklist)

1. `report`, `digest` and `snapshot` return bare data messages and never an
   error.
2. Only PCI functions of class `0x03` or `0x12` are inventoried.
3. NVIDIA rows merge into sysfs rows with the same normalized PCI address.
4. Stable rows contain no volatile field and no unknown value.
5. The digest is base64url SHA-256 of the canonical JSON of §5.3, and
   recomputing it from a report's `devices` and `topology` gives the
   report's `inventory-digest`.
6. Reordering devices in sysfs or in `nvidia-smi` output leaves the digest
   unchanged; volatile values never change it.
7. A missing `nvidia-smi` is not an error; a failing, slow or malformed run is
   reported in `errors`.
8. The sysfs root, the executable, the timeout and the reuse time come only
   from node options.
9. `nvidia-smi` is run without a shell; the device waits at most the
   configured timeout and reads at most 1 MiB of output.
10. `report` and `digest` reuse a report whose collection with the same
    configuration finished less than `gpu-inventory-cache-ms` ago, and the
    digest that `digest` returns always equals the `inventory-digest` of the
    report it was taken from.
11. Concurrent `report` and `digest` requests with the same configuration
    share one report collection; concurrent `snapshot` requests share one
    snapshot collection.

## 11. Out of scope

- Hardware attestation of the GPU; see `sev_gpu@1.0`.
- Vendors other than NVIDIA beyond what sysfs reports.
- Process lists, per-process memory, and MIG instance details.
- Policy decisions about which inventories are acceptable.
