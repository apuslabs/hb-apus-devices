---
title: Check runtime health
slug: check-runtime-health
---
# Check runtime health

Confirm that the model runtime behind the node is answering.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -o /dev/null -w '%{http_code}\n' "$HB/~inference@1.0/health"
```

Expected: `200`. Any other status means the runtime is down or still loading.
