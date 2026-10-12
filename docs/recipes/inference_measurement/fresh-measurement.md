---
title: Take a fresh measurement for a nonce
slug: fresh-measurement
---
# Take a fresh measurement for a nonce

Bind your own nonce and the node's GPU inventory into a fresh measurement.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_measurement@1.0/fresh?nonce=$NONCE" \
  | python3 -c 'import json,sys; b=json.load(sys.stdin)["body"]; print(b["purpose"], b["integration-mode"], b["gpu-inventory-digest"])'
```

Expected: `fresh`, the integration mode, and the GPU inventory digest (the
same value as `gpu_inventory@1.0/digest`). The body also carries `cpu-tee`,
`gpu-tee`, the full `gpu-inventory` and the node's commitment. When the host
measurement device is unavailable the mode is `observation-only` and
`failure` explains why.
