# agent@1.0

ReAct agent loop over an OpenAI-compatible LLM.

The device sends the conversation to the LLM, parses OpenAI `tool_calls`,
runs the requested built-in tools, appends the observations, and repeats until
the model returns a final answer or the iteration limit is reached.

## Keys

| Key | Method | Purpose |
|---|---|---|
| `run` | GET/POST | Runs one agent task and returns the final answer and the trace. |

## Request keys

- `agent-user-prompt`: the task. Default `Hello`.
- `agent-model`: model name sent to the LLM.
- `agent-max-iterations`: maximum ReAct turns. Default `10`.
- `agent-disable-tools`: `true` to answer without tools.
- `agent-api-peer`, `agent-api-path`, `agent-api-key`: LLM endpoint. These may
  also be set as node options.

## Built-in tools

HTTP requests, HyperBEAM cache lookup, message search, Arweave transaction
fetch, and bundling through the node's devices.

## Responses

200 with the base message plus `agent-answer` (the final answer) and
`agent-iterations`. When the loop stops early, `agent-error` explains why
(`max_iterations_exceeded`, a parse error, or the LLM call error) and
`agent-answer` carries a short message.
