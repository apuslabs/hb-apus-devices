---
title: Take a fresh measurement for a nonce
slug: fresh-measurement
---
# Take a fresh measurement for a nonce

Bind your nonce and the node's GPU inventory into a fresh host measurement and
a fresh GPU attestation, then check the binding yourself.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_measurement@1.0/fresh?nonce=$NONCE" | python3 -c '
import hashlib, json, sys
m = json.load(sys.stdin)
c = m.get("apus-gpu-composition", m)
binding = c["nonce-binding"]
digest = hashlib.sha256(json.dumps(binding, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
gpu = m["gpu-tee"]
print("envelope:     ", m["type"], c["integration-mode"])
print("your nonce:   ", binding["request-nonce"] == sys.argv[1])
print("GPU nonce:    ", gpu.get("nonce") == digest, "verified:", gpu["verified"])
print("CPU TEE:      ", m["cpu-tee"]["type"], "verified:", m["cpu-tee"]["verified"])' "$NONCE"
```

Expected on `hb.apus.network`: `lapee-measurement measurement-nonce`, `True`,
`True verified: true` and `amd-sev-snp verified: true`. The AMD SEV-SNP
report in `evidence` was taken for the same binding digest, base64url-encoded.
A node without a host measurement device answers with
`apus-gpu-system-measurement observation-only`, a node-signed observation
that makes no hardware claim.
