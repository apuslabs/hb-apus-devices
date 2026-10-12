---
title: Run the agent without tools
slug: run-without-tools
---
# Run the agent without tools

Run one ReAct turn that answers directly from the model.

```bash
HB=${HB:-https://hb.apus.network}
curl -s -H 'accept: application/json' -H 'accept-bundle: true' \
  "$HB/~agent@1.0/run?agent-user-prompt=Reply%20with%20the%20single%20word%20pong&agent-disable-tools=true&agent-model=google/gemma-4-26B-A4B-it&agent-max-iterations=1"
```

Expected: `agent-answer` is `pong` and `agent-iterations` is `1`. The response
also echoes the request keys.
