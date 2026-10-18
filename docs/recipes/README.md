# Device recipes

Each file is one `Device-Recipe` message: front matter (`title`, `slug`) for
the tags and markdown for the body. Directory names are device names without
`@1.0`.

`scripts/publish-recipes.escript` signs the recipes with the publishing
wallet and sets `recipe-for-device` to the specification ID of each device,
read from a preloaded store or from the publication record (`PUBLISH.md`):

```bash
make recipes WALLET=/path/to/wallet.json           # sign and print the IDs
make publish-recipes WALLET=/path/to/wallet.json   # upload and update PUBLISHED.md
```

Commands in the recipes target `HB=${HB:-https://hb.apus.network}`; set `HB`
to run them against another node.
