---
title: Run a chat completion
slug: chat-completion
---
# Run a chat completion

Send an OpenAI chat-completion request and read the answer.

Prerequisites:
- HyperBEAM node reachable with `HB=${HB:-https://hb.apus.network}`.
- `curl` and `python3`.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -X POST "$HB/~inference@1.0/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d '{"model":"google/gemma-4-26B-A4B-it","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":8,"temperature":0}' \
  | python3 -c 'import json,sys; t=sys.stdin.read(); d=json.JSONDecoder().raw_decode(t[t.index("{"):])[0]; print(d["object"], d["choices"][0]["message"]["content"])'
```

Expected: `chat.completion pong`. The body is the runtime's own
`chat.completion` object. The device returns complete responses only: a
request that reaches it with `"stream": true` is answered with status 400 and
`error.code` `streaming_unsupported`. On `hb.apus.network` the gateway sends
requests without `tee=true` straight to the runtime. To bind the response to
a GPU attestation, run the `attested-completion` recipe.
