---
title: Take a fresh measurement for a nonce
slug: fresh-measurement
---
# Take a fresh measurement for a nonce

Bind your own nonce and the node's GPU inventory into a fresh measurement.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl`, `openssl` and `python3`.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_measurement@1.0/fresh?nonce=$NONCE" \
  | python3 -c 'import json,sys; b=json.load(sys.stdin)["body"]; c=b.get("apus-gpu-composition", b); print(b.get("type"), b.get("measurement-device", "-"), c.get("integration-mode"), c.get("gpu-inventory-digest"))'
```

Expected, when the host measurement device works: `lapee-measurement snp@1.0
measurement-nonce <digest>`. The body then carries the AMD SEV-SNP `evidence`
(report and certificate chain) and `apus-gpu-composition.nonce-binding` with
your nonce and the GPU inventory digest. When hardware measurement is
unavailable the device falls back to `apus-gpu-system-measurement -
observation-only <digest>` and `failure` explains why. The digest equals
`gpu_inventory@1.0/digest`.
