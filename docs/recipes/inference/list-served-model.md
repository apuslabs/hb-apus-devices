---
title: List the served model
slug: list-served-model
---
# List the served model

Ask the node which model its inference runtime is serving.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s "$HB/~inference@1.0/v1/models"
```

Expected: an OpenAI model list. On `hb.apus.network` it contains
`google/gemma-4-26B-A4B-it` with `owned_by: sglang` and `max_model_len: 32768`.
The public gateway sends `/~inference@1.0/*` straight to the runtime, so this
is the runtime's `/v1/models`.
