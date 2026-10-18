---
title: Run an attested completion
slug: attested-completion
---
# Run an attested completion

Run a completion with `tee=true` and check that the GPU attestation is bound
to the exact request and response it covers.

Prerequisites:
- HyperBEAM node with a GPU attestation device, reachable with
  `HB=${HB:-https://hb.apus.network}`.
- `curl` and `python3`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -X POST "$HB/~inference@1.0/v1/chat/completions?tee=true" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}' \
  | python3 -c 'import hashlib,json,sys; t=sys.stdin.read(); d=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]; a=d["attestation"]; r=json.loads(a["raw"]); print(d["choices"][0]["message"]["content"], hashlib.sha256(a["raw"].encode()).hexdigest() == a["nonce"], a.get("verified"), sorted(r["request"]), d["resolved_model"].get("model"))'
```

Expected: `pong True True ['max_tokens', 'messages', 'model', 'tee',
'temperature'] google/gemma-4-26B-A4B-it`. `True` after the answer shows that
the attestation nonce is the SHA-256 of `raw`; the next value is the node's
own check of the GPU report. `raw` records the generation parameters and the
runtime's response, never HTTP headers or the caller's address. On
`hb.apus.network` the gateway sends this request to `inference@1.0` on the
node; its response carries no receipt, so the gateway does not publish it to
Arweave. The `chat-with-receipt` recipe with `"tee": true` publishes a
receipt.
