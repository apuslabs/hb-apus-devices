---
title: Generate GPU attestation evidence
slug: generate-evidence
---
# Generate GPU attestation evidence

Ask the node's NVIDIA GPU for attestation evidence bound to a nonce you choose.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
curl -s "$HB/~sev_gpu@1.0/generate?nonce=$NONCE" | python3 -c '
import json, sys
r = json.load(sys.stdin)
nonce = sys.argv[1]
print("nonce echoed:  ", r["nonce"] == nonce)
print("evidence nonce:", all(e["nonce"].lower() == nonce for e in r["evidences"]))
print("measurement:   ", [c["measres"] for c in r["claims"]])
print("verified:      ", r["verified"])' "$NONCE"
```

Expected: `True`, `True`, `['success']` (one entry per GPU) and `True`. The
full response also carries `claims` with NVIDIA's appraisal of each GPU and
`eat`, the detached Entity Attestation Token. A node without an available
attestation backend answers with status 503 and a JSON body such as
`{"error": "nvattest_not_found"}`.
