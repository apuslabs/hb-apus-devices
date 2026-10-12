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
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"]); print(sorted(d.get("receipt", {}).keys()))'
```

Expected: the answer `pong`, then the receipt's keys, including the request
and response digests and the node signature. On `hb.apus.network` the
explorer proxy also uploads the receipt to Arweave and adds
`load_dataitem_id`, so each run creates one Arweave data item.
