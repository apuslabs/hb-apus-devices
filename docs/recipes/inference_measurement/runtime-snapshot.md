---
title: Read the GPU runtime snapshot
slug: runtime-snapshot
---
# Read the GPU runtime snapshot

Read volatile GPU values such as temperature, power and utilization. They are
not part of any digest or binding.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_measurement@1.0/snapshot" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(s["type"], "supported:", s["supported"], "errors:", s["errors"])
for d in s["devices"]:
    print(d["pci-bdf"], d.get("temperature-c"), d.get("power-watts"), d.get("utilization-gpu-percent"))'
```

Expected: `apus-gpu-runtime-snapshot supported: true errors: []`, then one line
per GPU with its temperature (C), power draw (W) and utilization (%). When
`nvidia-smi` cannot be queried the snapshot reports `supported: false` and an
`errors` entry instead of failing.
