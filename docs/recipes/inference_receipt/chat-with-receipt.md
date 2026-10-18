---
title: Chat with a signed receipt
slug: chat-with-receipt
---
# Chat with a signed receipt

Run a short completion through the receipt device and inspect the receipt
that commits the request and response to the node.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl` and `python3`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -X POST "$HB/~inference_receipt@1.0/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}' \
  | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]; r=d["receipt"]; print(d["choices"][0]["message"]["content"], r["ao-core"]["status"], r["ao-core"]["verification-status"], r["node-address"])'
```

Expected: `pong captured verified` followed by the node's address. The
AO-Core HashPath of the execution is recorded and matches its transcript, and
the receipt is signed by that address. The node may return the JSON inside a
multipart body; the parser reads the first JSON object, so it accepts both.
Add `"tee": true` to the request to also attach the GPU attestation; on
`hb.apus.network` the gateway then publishes the record to Arweave and adds
`load_dataitem_id`, so such a run creates one Arweave data item.
