---
title: Verify a receipt's HashPath
slug: verify-receipt-hashpath
---
# Verify a receipt's HashPath

Create a receipt, then ask the node to recompute the HashPath of its recorded
AO-Core transcript and compare it with the recorded value.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl` and `python3`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -X POST "$HB/~inference_receipt@1.0/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}' \
  | python3 -c 'import json,sys; t=sys.stdin.read(); r=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]["receipt"]; print(json.dumps({"ao-core": r["ao-core"]}))' \
  | curl -s -X POST "$HB/~inference_receipt@1.0/verify-hashpath" \
      -H 'content-type: application/json' -H 'accept: application/json' \
      -H 'accept-bundle: true' --data-binary @- \
  | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]; b=d.get("body", d); print(b["verified"], b["hashpath-sources"], b["expected-hashpath"] == b["recomputed-hashpath"])'
```

Expected: `true ['ao-core.hashpath', 'response.priv.hashpath'] True`. The
node encodes `verified` as the string `true` (typed through `ao-types`). The
recorded response is linked to the recorded base message and request; both
recorded copies of the HashPath (the public `ao-core.hashpath` and the private
copy inside `verification-input-term`) match the recomputed value. A
transcript whose request differs from the recorded one yields `false` with
`reason` `hashpath-mismatch`.
