---
title: Verify returned evidence
slug: verify-evidence
---
# Verify returned evidence

Send the `evidences` from `generate` back for local verification.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
EVIDENCE=$(curl -s "$HB/~sev_gpu@1.0/generate?nonce=$NONCE" \
  | python3 -c 'import json,sys; e=json.load(sys.stdin)["evidences"]; print(e if isinstance(e,str) else json.dumps(e))')
curl -s -X POST "$HB/~sev_gpu@1.0/verify" --data-binary "$EVIDENCE"
```

Expected: `true` when the evidence verifies, `false` otherwise (including
when `generate` returned no evidence).
