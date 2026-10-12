---
title: Read the agent guide
slug: agent-guide
---
# Read the agent guide

Start from the node URL alone and learn how to discover its devices.

```bash
HB=${HB:-https://hb.apus.network}
curl -s "$HB/~docs@1.0/llms"
```

Expected: markdown that lists the discovery endpoints and every device the
node has loaded, with the APUS devices marked.
