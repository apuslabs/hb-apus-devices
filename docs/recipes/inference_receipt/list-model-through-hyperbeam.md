---
title: List the model through HyperBEAM
slug: list-model-through-hyperbeam
---
# List the model through HyperBEAM

Resolve `models` on the receipt device. Unlike `/~inference@1.0/*` on the
public gateway, this request is executed by the HyperBEAM node.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_receipt@1.0/models"
```

Expected: an OpenAI model list with the configured
`inference-opts/model_name` (`google/gemma-4-26B-A4B-it` on
`hb.apus.network`). No receipt is created for `models`.
