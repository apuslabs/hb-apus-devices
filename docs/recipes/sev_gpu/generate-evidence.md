---
title: Generate GPU attestation evidence
slug: generate-evidence
---
# Generate GPU attestation evidence

Ask the GPU for attestation evidence bound to your nonce.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
curl -s "$HB/~sev_gpu@1.0/generate?nonce=$NONCE"
```

Expected: JSON with `nonce` (your value), `verified`, `claims`, `eat` and
`evidences`. When the GPU or attestation SDK cannot produce evidence the
response is still 200 with `verified: false`, empty `claims` and
`evidences: null`.
