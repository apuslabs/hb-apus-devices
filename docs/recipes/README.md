# Device recipes

Each file is one `Device-Recipe` message: front matter for the tags, markdown
for the body. `scripts/publish-recipes.escript` signs them with the publishing
wallet and uploads them with `recipe-for-device` set to the device's
specification ID in the given preloaded store.

Directory names are device names without `@1.0`. Commands target
`HB=${HB:-https://hb.apus.network}`.
