---
title: Verify returned evidence
slug: verify-evidence
---
# Verify returned evidence

Generate evidence for your nonce and send it back for verification, pinning
the nonce you expect.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
curl -s "$HB/~sev_gpu@1.0/generate?nonce=$NONCE" \
  | curl -s -X POST -H 'content-type: text/plain' --data-binary @- \
      "$HB/~sev_gpu@1.0/verify?nonce=$NONCE"
```

Expected: `true`. The body may be the whole `generate` result or only its
`evidences` array. With any other `nonce` in the query the response is
`false`: the evidence is bound to the nonce it was collected for.
