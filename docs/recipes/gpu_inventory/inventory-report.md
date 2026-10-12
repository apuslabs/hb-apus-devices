---
title: Read the GPU inventory
slug: inventory-report
---
# Read the GPU inventory

List the PCI display devices the node observes.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~gpu_inventory@1.0/report"
```

Expected: `body.devices` lists each device with `pci-bdf`, `vendor-id`,
`device-id`, `class`, `driver` and `driver-version`. On `hb.apus.network`
it includes the NVIDIA H100 (`vendor-id` `0x10de`, driver `nvidia`) next to
the guest's virtual display adapter.
