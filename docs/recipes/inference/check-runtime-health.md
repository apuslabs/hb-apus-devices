---
title: Check runtime health
slug: check-runtime-health
---
# Check runtime health

Confirm that the model runtime behind the node is answering.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -o /dev/null -w '%{http_code}\n' "$HB/~inference@1.0/health"
```

Expected: `200` while the runtime's health endpoint answers 2xx. A runtime
that is down or still loading yields its own error status, or `503` when the
node cannot reach it.
