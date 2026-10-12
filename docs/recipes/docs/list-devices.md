---
title: List loaded devices as JSON
slug: list-devices
---
# List loaded devices as JSON

Get every loaded device with its specification ID, signers, recipe count
and links.

```bash
HB=${HB:-https://hb.apus.network}
curl -s "$HB/~docs@1.0/devices" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(x["name"], x["recipes"]) for x in d["devices"] if x["apus"]]'
```

Expected: one line per APUS device with its number of recipes.
