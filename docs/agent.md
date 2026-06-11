# agent@1.0

`agent@1.0` implements a ReAct loop on top of an OpenAI-compatible LLM endpoint.

The device calls `inference@1.0`, parses OpenAI `tool_calls`, executes built-in tools, appends observations to the message history, and repeats until the model returns a final text answer or `agent-max-iterations` is reached.

## Request

Call:

```erlang
hb_ao:resolve(
    #{<<"device">> => <<"agent@1.0">>},
    #{<<"path">> => <<"run">>,
      <<"agent-user-prompt">> => <<"What is 2+2?">>,
      <<"agent-api-peer">> => <<"https://api.example.com">>,
      <<"agent-api-path">> => <<"/v1/chat/completions">>,
      <<"agent-api-key">> => <<"sk-...">>},
    #{}
).
```

## Configuration

- `agent-user-prompt`: initial user message.
- `agent-model`: model name, default `gpt-4o-mini`.
- `agent-max-iterations`: max ReAct turns, default `10`.
- `agent-api-peer`: OpenAI-compatible base URL.
- `agent-api-path`: chat-completions path.
- `agent-api-key`: optional bearer token.

## Tools

The default tool executor supports HTTP requests, cache lookup, message search, Arweave transaction fetch, and bundling through HyperBEAM built-in devices.
