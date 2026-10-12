---
title: Run a chat completion
slug: chat-completion
---
# Run a chat completion

Send an OpenAI chat-completion request and read the answer.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -X POST "$HB/~inference@1.0/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}'
```

Expected: a `chat.completion` object whose `choices[0].message.content` is
`pong`. Add `"tee": true` to the body to route the request through
`inference_receipt@1.0` and receive GPU attestation and a receipt.
