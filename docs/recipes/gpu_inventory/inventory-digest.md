---
title: Get the inventory digest
slug: inventory-digest
---
# Get the inventory digest

Get the stable digest of the static inventory fields.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~gpu_inventory@1.0/digest"
```

Expected: `body.inventory-digest` (43 characters, base64url),
`provenance-class: host-observed` and `type: apus-gpu-inventory-digest`.
Repeated calls return the same digest while the hardware and driver are
unchanged.
