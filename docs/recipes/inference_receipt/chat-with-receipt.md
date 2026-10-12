---
title: Chat with a signed receipt
slug: chat-with-receipt
---
# Chat with a signed receipt

Run a short completion through the receipt decorator and inspect the
receipt that commits the request and response to the node.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl` and `python3`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -X POST "$HB/~inference_receipt@1.0/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}' \
  | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.loads(t[t.index("{"):t.rindex("}")+1]); print(d["choices"][0]["message"]["content"]); print(d["receipt"]["ao-core"]["status"], sorted(d["receipt"])[:6])'
```

Expected: the answer `pong`, then `captured` (the AO-Core HashPath of the
execution is recorded) and the first receipt keys. The node may return the
JSON as the only part of a multipart body; the parser above accepts both. On `hb.apus.network` the
explorer proxy also uploads the receipt to Arweave and adds
`load_dataitem_id`, so each run creates one Arweave data item.
