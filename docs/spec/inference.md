# inference@1.0

OpenAI-compatible LLM inference served by this HyperBEAM node.

The device forwards OpenAI chat-completion requests to the node's model
runtime and returns the runtime's JSON. On the APUS H100 node the runtime is
SGLang serving `google/gemma-4-26B-A4B-it` inside an SEV-SNP guest with an
NVIDIA H100 in confidential-computing mode.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `v1` | POST | OpenAI-style router. `/~inference@1.0/v1/chat/completions` reaches `completions`. |
| `chat` | POST | Marks the request as a chat request and forwards to `completions`. |
| `completions` | POST | Sends the request to the runtime's `/v1/chat/completions`. |
| `models` | GET | Lists the served model. The name comes from `inference-opts/model_name`. |
| `health` | GET | Returns 200 with an empty body when the runtime answers its health check. |

## Request

`completions` accepts either a JSON `body`, sent unchanged to the runtime, or
OpenAI parameters as message keys: `model`, `messages`, `prompt`,
`max_tokens`, `temperature`, `top_p`, `top_k`, `n`, `stop`, `seed`, `tools`,
`tool_choice`, `presence_penalty`, `frequency_penalty`, `repetition_penalty`,
`logit_bias`, `user`, `stream`.

- `tee=true` attaches `sev_gpu@1.0` GPU attestation to a non-streaming response.
  Its `raw` field (whose SHA-256 is the attestation nonce) records only the
  generation parameters sent to the runtime and `tee`; `user`, HTTP headers
  and the caller's IP are never recorded.
- `stream=true` returns server-sent events from the runtime.

## Node options

- `agent-api-peer`: runtime base URL (default `http://localhost:30001`).
- `agent-api-path`: runtime path (default `/v1/chat/completions`).
- `agent-api-key`: optional bearer token for the runtime.
- `inference-opts/model_name`: model ID reported by `models`.

## Responses

Success is the runtime's OpenAI JSON with `status` 200 and
`content-type: application/json`. Runtime errors are passed through with
their status code.

## Public gateway routing

`https://hb.apus.network` sits behind the APUS explorer proxy. Requests to
`/~inference@1.0/*` without `tee=true` are sent straight to the model runtime,
with the device prefix removed (so `/~inference@1.0/v1/models` is the runtime's
`/v1/models`). A request with `tee=true` goes to HyperBEAM instead:
`inference@1.0` adds `sev_gpu@1.0` attestation, and the proxy uploads the
attestation record to Arweave and returns its `load_dataitem_id`. The legacy
`/~inference@1.0/completions` path with `tee=true` is rewritten to
`inference_receipt@1.0`. Call the node port directly to exercise the device
itself, and read this device's schema from
`/~docs@1.0/device-schema?name=inference@1.0`.

## Related devices

- `inference_receipt@1.0` wraps this device and returns a signed receipt.
- `sev_gpu@1.0` supplies GPU attestation for `tee=true`.
- `agent@1.0` uses this device as its LLM.
