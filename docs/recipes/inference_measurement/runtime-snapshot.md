---
title: Read the GPU runtime snapshot
slug: runtime-snapshot
---
# Read the GPU runtime snapshot

Read volatile GPU facts from `nvidia-smi`. These values are not part of any
digest.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_measurement@1.0/snapshot"
```

Expected: `body.type` is `apus-gpu-runtime-snapshot` with `supported`,
`devices` and `errors`. When `nvidia-smi` cannot be queried the body reports
`supported: "false"` and an `errors` entry instead of failing.
