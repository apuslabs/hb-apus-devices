---
title: List the served model
slug: list-served-model
---
# List the served model

Ask the node which model its inference runtime is serving.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl` and `python3`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s "$HB/~inference@1.0/v1/models" \
  | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]; print([m["id"] for m in d["data"]])'
```

Expected: the model IDs from the runtime's own `/v1/models` list, unchanged by
the device. On `hb.apus.network` the list is `['google/gemma-4-26B-A4B-it']`.
