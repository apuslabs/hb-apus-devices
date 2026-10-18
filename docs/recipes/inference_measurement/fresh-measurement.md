---
title: Take a fresh measurement for a nonce
slug: fresh-measurement
---
# Take a fresh measurement for a nonce

Bind your nonce and the node's GPU inventory into a fresh host measurement and
a fresh GPU attestation, then check both halves of the binding yourself.

```bash
HB=${HB:-https://hb.apus.network}
NONCE=$(openssl rand -hex 32)
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~inference_measurement@1.0/fresh?nonce=$NONCE" | python3 -c '
import base64, hashlib, json, sys
m = json.load(sys.stdin)
c = m.get("apus-gpu-composition", m)
binding = c["nonce-binding"]
d = hashlib.sha256(json.dumps(binding, sort_keys=True, separators=(",", ":"),
                              ensure_ascii=False).encode()).digest()
host_nonce = base64.urlsafe_b64encode(d).rstrip(b"=").decode()
gpu = m["gpu-tee"]
print("envelope:  ", m["type"], c["integration-mode"])
print("your nonce:", binding["request-nonce"] == sys.argv[1])
print("SNP nonce: ", m.get("evidence", {}).get("nonce") == host_nonce)
print("GPU nonce: ", gpu.get("nonce") == d.hex(), "verified:", gpu["verified"])
print("CPU TEE:   ", m["cpu-tee"]["type"], "verified:", m["cpu-tee"]["verified"])' "$NONCE"
```

Expected on `hb.apus.network`: `lapee-measurement measurement-nonce`, `True`,
`True`, `True verified: true` and `amd-sev-snp verified: true`. The SEV-SNP
report in `evidence` carries base64url(D) and the GPU evidence carries hex(D),
where D is the SHA-256 of the binding; `cpu-tee.verified` is the base
device's check that the report commits to that nonce. A node without a host
measurement device answers with `apus-gpu-system-measurement
observation-only`, a node-signed observation that makes no hardware claim;
its `SNP nonce` line prints `False`.
