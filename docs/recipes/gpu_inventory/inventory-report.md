---
title: Read the GPU inventory
slug: inventory-report
---
# Read the GPU inventory

List the GPUs and display devices the node observes.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~gpu_inventory@1.0/report" | python3 -c '
import json, sys
r = json.load(sys.stdin)
for d in r["devices"]:
    print(d["pci-bdf"], d.get("vendor-id"), d.get("driver", "-"), d.get("name", ""))
print("sources:", r["provenance"]["sources"], "errors:", r["errors"])'
```

Expected: one line per device, sorted by PCI address. On `hb.apus.network`
the guest's virtual display adapter (`0000:00:01.0 0x1234 bochs-drm`) and the
NVIDIA H100 (`0000:01:00.0 0x10de nvidia NVIDIA H100 PCIe`), whose sysfs and
`nvidia-smi` facts are merged into one entry, then
`sources: ['nvidia-smi', 'sysfs'] errors: []`.
