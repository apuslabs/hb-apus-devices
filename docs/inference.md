# inference@1.0

`inference@1.0` exposes an OpenAI-compatible inference interface for local or remote LLM backends.

## Exports

- `completions`
- `chat`
- `models`
- `health`
- `v1`

## Backend Routing

The device relays requests through `relay@1.0`.

- `agent-api-peer`: backend base URL, default `http://localhost:8080`.
- `agent-api-path`: backend path, defaults to `/v1/completions` or `/v1/chat/completions`.
- `agent-api-key`: optional bearer token.

## TEE Attestation

Set `tee=true` on a non-streaming request to include `sev_gpu@1.0` attestation data in the response body.
