# Device recipes

Each file is one `Device-Recipe` message: front matter (`title`, `slug`) for
the tags and markdown for the body. Directory names are device names without
`@1.0`.

`scripts/publish-recipes.escript` signs the recipes with the publishing
wallet and sets `recipe-for-device` to the specification ID of each device:

```bash
make recipes WALLET=/path/to/wallet.json           # dry run against the local preloaded store
make publish-recipes WALLET=/path/to/wallet.json   # upload against PUBLISH.md and update PUBLISHED.md
```

`make publish-recipes` reads the specification IDs from the publication
record (`PUBLISH.md`) and requires the wallet that signed the published
specifications. Each uploaded recipe is appended to `PUBLISHED.md` as soon
as the bundler accepts it.

Commands in the recipes target `HB=${HB:-https://hb.apus.network}`; set `HB`
to run them against another node.
