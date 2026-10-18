---
title: Recompute the inventory digest
slug: inventory-digest
---
# Recompute the inventory digest

Fetch the inventory and recompute its digest from the reported devices and
topology.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~gpu_inventory@1.0/report" | python3 -c '
import base64, hashlib, json, sys
r = json.load(sys.stdin)
canonical = json.dumps({"devices": r["devices"], "topology": r["topology"]},
                       sort_keys=True, separators=(",", ":"), ensure_ascii=False)
digest = base64.urlsafe_b64encode(hashlib.sha256(canonical.encode()).digest()).rstrip(b"=").decode()
print(digest, digest == r["inventory-digest"])'
curl -s -H 'accept: application/json' "$HB/~gpu_inventory@1.0/digest" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["inventory-digest"])'
```

Expected: a 43-character base64url digest followed by `True`, then the same
digest from `digest`. Repeated calls return the same value while the hardware,
driver and firmware are unchanged.
