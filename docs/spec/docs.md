# docs@1.0

Self-documentation for the devices this node has loaded.

The device reads the node's preloaded device index and, for each device,
shows its Device-Specification, the schema extracted from the loaded
implementation's Erlang `-spec` declarations, and Device-Recipe messages
published on Arweave. It describes only what this node can run.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `index` | GET | HTML index of loaded devices. Also served for `/~docs@1.0`. |
| `device` | GET | HTML page for one device: spec, schema and recipes. Takes `name`. |
| `devices` | GET | JSON list of devices with spec IDs, signers, schema functions and recipe counts. |
| `spec` | GET | The device's specification as `text/markdown`. Takes `name`. |
| `recipes` | GET | The device's recipes as `text/markdown`. Takes `name`. |
| `llms` | GET | Plain-text guide for agents: how to discover and call devices here. |

Each device's own schema is at `/~<device>/schema`; this device links to it.

## Recipes

A recipe is an Arweave message with `type=Device-Recipe`,
`content-type=text/markdown` and `recipe-for-device` set to the device's
specification ID. The device also accepts recipes whose `primary-device`
matches the device name when the author is a trusted recipe signer, so that
recipes survive a rebuild that re-signs the specification.

A recipe is marked official when its author signed the specification or is
listed in the node option `docs-recipe-signers`.

## Node options

- `docs-recipe-signers`: extra addresses whose recipes are official.
- `docs-graphql-url`: GraphQL endpoint (default `https://arweave.net/graphql`).
- `docs-gateway-url`: data gateway (default `https://arweave.net`).
- `docs-highlight-devices`: devices listed first on the index.
- `docs-public-url`: base URL shown in the agent examples (default
  `https://hb.apus.network`).

Recipe lookups are cached for five minutes. Gateway errors are shown on the
page and do not fail the request.
