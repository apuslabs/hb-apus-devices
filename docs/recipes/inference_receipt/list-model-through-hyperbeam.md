---
title: List the model through HyperBEAM
slug: list-model-through-hyperbeam
---
# List the model through HyperBEAM

Resolve `models` on the receipt device. This request is always executed by
the HyperBEAM node, which asks the configured runtime.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_receipt@1.0/models"
```

Expected: the runtime's OpenAI model list, as `inference@1.0/models` returns
it (`google/gemma-4-26B-A4B-it` on `hb.apus.network`). No receipt is created
for `models`.
