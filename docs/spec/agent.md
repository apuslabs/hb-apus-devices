# `agent@1.0` — tool-using agent loop over an OpenAI-compatible chat model

- **Depends-on:** `inference@1.0` (default model device), `relay@1.0` (`http_request`), `cache@1.0` (`lookup_data`), `query@1.0` (`search_messages`), `arweave@2.9` (`get_arweave_tx`), `bundler@1.0` and `ans104@1.0` (`bundle_item`, only when enabled)
- **Status:** Stable
- **Maintainer:** Apus Network (https://apus.network)

## 1. Overview

`agent@1.0` runs one agent task per request. It sends a conversation to a
chat-completion model, executes the built-in tools the model asks for, appends
each result to the conversation and calls the model again, until the model
gives a final answer or an iteration limit is reached (the Reason-Act-Observe,
or ReAct, pattern).

The device is pure orchestration. The model is reached by resolving an
inference device (default `inference@1.0`), and every tool is executed by
resolving another device. The device is stateless: a conversation lives for one
`run` and nothing is written to the node's store.

Authority is split by source. The node operator decides where model calls go,
which devices execute tools, which tools exist and every limit. A request
supplies the task, the conversation and choices that can only narrow what the
agent may do. Each completion's OpenAI `finish_reason` decides the next step:
`stop` answers, `tool_calls` executes tools, `length` continues a truncated
answer, and every other value ends the run with an error code.

The reference deployment is `https://hb.apus.network`.

## 2. Concepts & terminology

- **Run:** one resolution of the `run` key.
- **Model call (iteration):** one resolution of `completions` on the inference
  device. `agent-iterations` counts the model calls made in a run.
- **Finish reason:** the `finish_reason` of the first choice of a completion.
- **Tool table:** the device's built-in list of tools (§4). Each entry
  holds a name, a description, JSON-schema properties, the required arguments,
  a default executor device and, for `bundle_item`, the node option that
  enables it. Tool definitions, the tool lines of the system prompt, accepted
  argument keys and dispatch are all derived from this table.
- **Enabled tool set:** the tools offered to the model and executable in one
  run (§4, step 1). A tool outside this set is never executed.
- **Tool call / tool message:** a function call requested by the model / the
  `tool` message carrying the text result of that call.
- **Assistant frame:** the assistant message the device appends to the
  conversation after a completion that does not end the run.
- **Partial answer:** text collected from `length` completions; it prefixes the
  final answer and is cleared by a tool round.
- **Node option:** a value of the node message, read with `hb_opts:get/3`.
  Request and base messages are caller-controlled and are never read as node
  options.

## 3. Device interface

- **Dispatch shape:** explicit keys. The device answers one key, `run`, and
  `info/1` returns `exports => [<<"run">>]`. Any other key is not handled by
  this device and resolves under `message@1.0`.
- **Inputs:** `run` reads its inputs from the request message only. The base
  message is never read for inputs; it is echoed in the result (§4).
- **Invocation:** `GET` or `POST` `/~agent@1.0/run` with the request keys as
  query parameters or body keys, or in process with `hb_ao:resolve/3`.

| Request key | Accepted values | Default | Effect |
|---|---|---|---|
| `agent-user-prompt` | text (§5.6) | `Hello` | User message of the default conversation. |
| `agent-messages` | chat messages (§5.2) | default conversation | The complete initial conversation. |
| `agent-system-prompt` | text (§5.6) | generated (§5.3) | Replaces the generated system prompt. |
| `agent-model` | text (§5.6) | node option `agent-default-model` | `model` field of every model call. |
| `agent-max-iterations` | positive integer (§5.6) | `10` | Maximum model calls, capped by `agent-max-iterations-limit`. |
| `agent-disable-tools` | boolean (§5.6) | `false` | No tool is offered or executable. |
| `agent-tools` | tool names (§5.6) | every enabled tool | Narrows the enabled tool set. |
| `agent-tool-choice` | `auto`, `none`, `required`, or a named-function object | `auto` | `tool_choice` until the first tool round. |

Empty text counts as absent for `agent-user-prompt`, `agent-system-prompt` and
`agent-model`. No other request key is read; in particular `agent-api-peer`,
`agent-api-path`, `agent-api-key` and request keys named like the node options
below have no effect.

| Node option | Default | Effect |
|---|---|---|
| `agent-inference-device` | `inference@1.0` | Device whose `completions` key serves model calls. |
| `agent-default-model` | none | Model used when the request has no `agent-model`. With neither, model calls carry no `model` field and the runtime chooses. |
| `agent-max-iterations-limit` | `25` | Ceiling of the effective iteration limit. |
| `agent-max-tool-result-bytes` | `4000` | Byte bound of each tool message content (§5.5). |
| `agent-allow-bundle` | `false` | When true, `bundle_item` is part of the tool table. |
| `agent-http-allow-private` | `false` | When true, `http_request` skips its local-address check (§7). |
| `agent-tool-devices` | none | Map from tool name (`http_request` or `http-request` form) to the device that executes it. |

Numeric and boolean node options are interpreted like request values (§5.6);
an invalid value means the default.

## 4. Resolved keys (normative)

### `run` — run one agent task

- **Reads:** the request keys and node options of §3. The base message is read
  only to build the result.
- **Behaviour:**
  1. **Enabled tool set.** If `agent-disable-tools` is true, the set is empty.
     Otherwise it is the tool table without `bundle_item` unless
     `agent-allow-bundle` is true, narrowed to the names listed in
     `agent-tools` when that key holds names (§5.6). Unknown names are ignored,
     table order is kept, and `agent-tools` never adds a tool.
  2. **System prompt.** `agent-system-prompt`, or the prompt generated from the
     enabled tool set (§5.3).
  3. **Initial conversation.** Usable `agent-messages` (§5.2) are the
     conversation; a system message with the prompt from step 2 is prepended
     when they contain none. Otherwise the conversation is a system message
     and a user message holding `agent-user-prompt` (default `Hello`).
  4. **Model.** `agent-model`, else `agent-default-model`, else none.
  5. **Tool choice.** None when the enabled set is empty. Otherwise
     `agent-tool-choice` when it is `auto`, `none`, `required` or a
     named-function object (as a map or JSON text), normalized to
     `{"type":"function","function":{"name":N}}`; any other value means `auto`.
  6. **Iteration limit.** `min(R, L)`, where `R` is `agent-max-iterations`
     (default `10`) and `L` is `agent-max-iterations-limit` (default `25`).
  7. **Loop.** Before model call number `i` (from 1), if `i` exceeds the limit
     the run ends with `max_iterations_exceeded` and `agent-iterations` equal
     to the limit. Otherwise the device makes the call (§5.1) and acts on the
     finish reason as listed under *Finish-reason dispatch*. A failed model
     call or an unusable response ends the run as listed in §8.
- **Returns:** `{ok, Result}` for every run. `Result` is the base message
  without `commitments` and without the four output keys, plus:
  - `agent-answer`: the final answer, or the sentence listed in §8 when the run
    ended with an error.
  - `agent-iterations`: the number of model calls made (positive integer).
  - `agent-error`: present only when the run ended without a final answer; a
    code from §8.
  - `agent-error-detail`: present with `agent-error`; a map described in §8.
- **Side effects:** model calls through the inference device; the effects of
  executed tools: outbound HTTP (`http_request`), cache and Arweave reads, and,
  only when enabled, a signed upload to Arweave (`bundle_item`). The device
  writes nothing to the store itself.

#### Finish-reason dispatch

| Finish reason | Condition | Action |
|---|---|---|
| `stop` | none | Final answer: partial answer followed by the answer text (§5.4). Tool calls in the message are not executed. |
| `tool_calls` | non-empty `tool_calls` | Execute them (*Tool execution*), append the assistant frame and one tool message per call, clear the partial answer, set the tool choice to `auto`, next call. |
| `tool_calls` | no tool calls | `incomplete_response`, cause `missing-tool-calls`. |
| `length` | any tool call in the message | `incomplete_response`, cause `truncated-tool-call`. Nothing is executed. |
| `length` | empty visible text | `incomplete_response`, cause `empty-content`. |
| `length` | visible text | Append the text to the partial answer, append the assistant frame and the continuation message (§5.3), next call. |
| `content_filter` | none | `content_filtered`. |
| `error` | none | `model_error`. |
| absent or `null` | none | Treated as `tool_calls` when the message has a non-empty `tool_calls` list, else as `stop`. |
| any other value | none | `unsupported_finish_reason`. |

"Any tool call" means a non-empty `tool_calls` list or a `function_call`
object. Each continuation is a model call and counts against the limit.

#### Tool execution

The calls of one completion run sequentially in their order. The first 16 are
executed; each further call receives a tool message saying it was not
executed. For each executed call:

1. The call is normalized: `id` (a missing or empty id becomes `call_<n>`,
   `n` being its 1-based position), function `name`, and `arguments`.
2. A name outside the enabled tool set is not executed; the tool message lists
   the available tools.
3. `arguments` MUST be a JSON object, given as JSON text or as an object.
   Invalid JSON, or valid JSON that is not an object, is not executed; the tool
   message states which, the argument size in bytes and a preview of at most
   160 bytes (§5.5).
4. Arguments are filtered to the keys of the tool's schema properties.
5. The executor validates the arguments (a failed validation executes nothing)
   and resolves the tool's device: the `agent-tool-devices` entry for the tool,
   else the table default.
6. An exception raised during execution becomes a failure message; the run
   continues.

Messages for calls that were not executed read
`` Tool error: `<name>` was not executed: <reason>. No state was changed. ``
and failures read `` Tool error: `<name>` failed: <reason>. ``

#### Built-in tools

Every executor resolves its device with the base message `{device: <device>}`
and the request message shown, using the node options plus
`hashpath => ignore` and `cache-control => [no-store, no-cache]`.

| Tool | Device and key | Arguments (required in bold) | Request message |
|---|---|---|---|
| `http_request` | `relay@1.0` `call` | **`url`**, `method`, `body`, `content_type` | `path=call`, `target=payload`, `payload={path: url, method[, body, content-type]}` |
| `lookup_data` | `cache@1.0` `read` | **`id`** | `path=read`, `read=id` |
| `search_messages` | `query@1.0` `only` | **`match`**, `return` | `path=only`, `only=match`, `return` |
| `get_arweave_tx` | `arweave@2.9` `tx` | **`id`** | `path=tx`, `tx=id`, `method=GET`, `exclude-data=true` |
| `bundle_item` | `bundler@1.0` `item` | **`data`**, `content_type` | `path=item`, `bundler-subject=item`, `item=<signed item>` |

- `http_request`: `url` MUST be an absolute `http` or `https` URL with a host
  and pass the address check of §7. `method` is `GET` (default), `POST`, `PUT`
  or `DELETE`, case-insensitive. A text `body` is sent with `content_type`
  (default `text/plain`); an object or array `body` is sent as JSON with default
  type `application/json`. The result is `status: <status>`, a
  `content-type: <type>` line when the response has one, an empty line and the
  response body. Responses with 4xx or 5xx status are results, not failures.
- `lookup_data` and `get_arweave_tx`: `id` MUST be 43 characters of base64url.
  Not-found results read `Not found: <id>` and `Transaction not found: <id>`.
- `search_messages`: `match` MUST be a non-empty object whose values are
  strings, numbers or booleans; `return` is `paths` (default), `messages` or
  `count`. A not-found result reads `No matching messages.`
- `bundle_item`: exists only when `agent-allow-bundle` is true. The device
  builds `{data, content-type}` (`content_type`, default `text/plain`), commits
  it with `ans104@1.0` using the node's wallet, and submits it. The result reads
  `Submitted data item <id> to the node's bundler.` when the bundler returns an
  `id`.

## 5. Data formats & encodings

### 5.1 Model calls

The device resolves `completions` on the inference device with the base message
`{device: <agent-inference-device>}` and the request message
`{path: completions, body: <payload JSON>}`, using the node options plus
`hashpath => ignore` and `cache-control => [no-store, no-cache]`. Nothing else
is sent; the inference device takes its runtime address and credentials from
its own node options. The payload has `messages`, `model` when one is set, and
`tools` with `tool_choice` when the enabled tool set is non-empty:

```json
{
  "model": "google/gemma-4-26B-A4B-it",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant ..."},
    {"role": "user", "content": "What does the message with this ID contain?"}
  ],
  "tools": [
    {"type": "function", "function": {
      "name": "lookup_data",
      "description": "Read a message or data item from the node's cache by its 43-character ID.",
      "parameters": {"type": "object", "properties": {"id": {"type": "string", "description": "43-character base64url ID."}},
                     "required": ["id"], "additionalProperties": false}}}
  ],
  "tool_choice": "auto"
}
```

The response is read from the call's result: a map whose `status` is 400 or
more is a failure; otherwise its `body` (JSON text or a map) is the response,
or the map itself when it has no `body` but has `choices`. A binary result is
JSON text. The response is a failure when it carries an error envelope (an
`error` object or text, or `"object": "error"`), and unusable when it has no
first choice with a `message` object.

### 5.2 Caller conversation

`agent-messages` is usable when it is a non-empty list of objects, a JSON
array text, or a message with the ordinal keys `1` to `N`, and every element
is an object whose `role` is `system`, `user`, `assistant` or `tool`, and the
list encodes as JSON. Elements are passed to the model unchanged. A value that
is absent or not usable selects the default conversation of §4, step 3; it is
never an error.

### 5.3 Generated text

The generated system prompt is the preamble
`You are a helpful assistant running on a HyperBEAM node in the AO network.`,
a space, and either `Answer the user's request directly and concisely.` (empty
tool set) or the tool text, with one line per enabled tool in table order:

```text
You can call these tools:
- <name>: <description>
...
Call a tool only when you need information or an action that it provides. When you have enough information, reply with the final answer as plain text and do not call any tool. Keep answers concise.
```

The continuation message after a `length` completion is the user message
`Continue exactly where your previous message stopped. Do not repeat any text you have already written.`

### 5.4 Conversation frames

- **Visible text** of an assistant message: `content` when it is text; the
  concatenated `text` fields of its parts when it is an array; otherwise
  empty. The **answer text** is the visible text, or `refusal` when the
  visible text is empty and `refusal` is text.
- **Assistant frame:** `role: assistant`, `content` (the visible text, or
  `null` when empty), the normalized `tool_calls` for a tool round
  (`id`, `type: function`, `function: {name, arguments}` with object arguments
  encoded as JSON text), and `reasoning_content` and `reasoning` when the
  completion carried them as text, so reasoning models keep their context.
- **Tool message:** `role: tool`, `tool_call_id`, `content` (the result text).

### 5.5 Text bounds

Tool message contents, argument previews and error details are valid UTF-8:
the first `B` bytes are kept, the cut never splits a character, and invalid
byte sequences are replaced with U+FFFD. When the text was longer, it ends with
`\n[truncated: <kept> of <original> bytes shown]`. `B` is
`agent-max-tool-result-bytes` for tool messages, 160 for argument previews and
512 for error detail text. Tool results that are not binaries are rendered as
JSON after loading links and removing `commitments` and `priv` keys at every
level (Erlang term text when not encodable as JSON).

### 5.6 Value forms

- **Text:** a binary, or a number converted to its decimal text. Other values
  count as absent.
- **Boolean:** `true`, the integer `1`, or the text `true` or `1`
  (case-insensitive, surrounding whitespace ignored). Anything else is false.
- **Positive integer:** an integer above 0, an integral float of at least 1,
  or decimal text (surrounding whitespace ignored) above 0. HTTP query values
  arrive as text and are accepted. Anything else means the default.
- **Tool names (`agent-tools`):** a list of names, a JSON array text, or
  comma-separated text; names are trimmed. Other value types leave the tool
  set unchanged.

## 6. Ordering, freshness & caching

- Model calls are strictly sequential; each sees the full conversation so far.
  Tool calls of one completion execute in order, and their tool messages
  follow the assistant frame in the same order.
- `run` is not a pure function: it depends on the model, on remote HTTP
  endpoints and on cache contents at the time of the call. Every nested call
  is made with `hashpath => ignore` and `cache-control => [no-store,
  no-cache]`. The `run` result itself carries no cache directive; a node that
  enables result storing SHOULD exclude `/~agent@1.0/run`.
- No state survives a run. Callers that need memory pass the conversation in
  `agent-messages`.

## 7. Security & authority

- **Routing comes only from node options.** The inference device, the tool
  devices, the default model, every limit and every policy switch are node
  options. The device forwards no request key to the inference device, so a
  request cannot choose a backend, peer, path or credential.
- **Execution authority comes only from the tool table and node options.**
  `agent-tools` and `agent-disable-tools` can only remove tools. A model can
  only run enabled tools, only with object arguments, and only with the keys
  of the tool's schema. Arguments that are not a JSON object, and tool calls
  from a truncated (`length`) completion, are never executed.
- **`http_request` address checks.** The device refuses, before any network
  activity, URLs that are not absolute `http`/`https`, hosts named
  `localhost` or ending in `.localhost`, and IP-address literals (including
  short and integer IPv4 forms and IPv6) that are not public unicast
  addresses under HyperBEAM's hostname policy: loopback, private, link-local,
  unspecified, shared, documentation, multicast and other special-use ranges,
  IPv4-mapped forms, and addresses on the node's own interface subnets.
  Names are not resolved by this device; `relay@1.0` applies DNS-based checks
  under its `relay-block-internal` (default true) and `relay-allowed-hosts`
  options. `agent-http-allow-private` disables only this device's check; to
  reach private hosts the relay policy MUST also allow them.
- **`bundle_item` writes with the node's identity.** When enabled, data chosen
  by the model is signed with the node's wallet and uploaded permanently, at
  the node's cost. It is disabled by default and cannot be enabled by a
  request. Tool results are untrusted input: content fetched by
  `http_request` can steer the model, which operators SHOULD weigh before
  enabling writes.
- **Bounded work.** A run makes at most `agent-max-iterations-limit` model
  calls and at most 16 tool executions per completion, and each tool message
  is bounded by `agent-max-tool-result-bytes`.
- **Result echo.** The result echoes the base message, which for HTTP
  requests contains the request keys and transport fields attached by the
  node. It is returned to the caller only.

## 8. Errors

A run that ends without a final answer still returns `{ok, Result}`;
`agent-error` holds one of these codes:

| `agent-error` | `agent-answer` | `agent-error-detail` | Raised when |
|---|---|---|---|
| `max_iterations_exceeded` | `Max iterations reached. Could not complete the task.` | `limit` | The limit is reached before a final answer. |
| `content_filtered` | `The model response was blocked by a content filter.` | `finish-reason` | Finish reason `content_filter`. |
| `incomplete_response` | `The model response was incomplete.` | `finish-reason`, `cause` | See the table in §4. |
| `unsupported_finish_reason` | `The model stopped for an unsupported reason.` | `finish-reason` | Any finish reason not listed in §4. |
| `model_error` | `The model call failed.` | `status`, `message`, `type`, `code`, `finish-reason` (each when known) | The inference call returned an error, a status of 400 or more, or an error envelope, raised an exception, or the finish reason is `error`. |
| `invalid_response` | `The model response could not be parsed.` | `message` | The response is not a JSON object or has no first choice with a message. |

`message`, `type` and `code` come from the runtime's error envelope when there
is one; otherwise `message` is a preview of the error body or a description of
the error. Tool failures are not run errors: they are reported to the model in
tool messages (§4) and the run continues.

## 9. Composition

- **Model device.** `agent-inference-device` may name any device whose
  `completions` key accepts an OpenAI chat payload in `body` and returns the
  OpenAI response as described in §5.1. With the default `inference@1.0`, the
  runtime address, path and key are that device's node options (see its
  specification); the agent adds none.
- **Tool devices.** `agent-tool-devices` routes a tool to another device, for
  example a filtering HTTP proxy. The replacement MUST answer the same key
  with the same request message as the default device.
- **Conversations.** Callers with memory keep the transcript themselves and
  send it in `agent-messages` on every run.
- **Lua.** A process can call the device in place:

```lua
ao.resolve({ path = "/~agent@1.0/run",
             ["agent-user-prompt"] = "Summarize the item.",
             ["agent-tools"] = "lookup_data" })
```

- **HTTP.**

```bash
curl -s -H 'accept: application/json' \
  "https://hb.apus.network/~agent@1.0/run?agent-user-prompt=Reply%20with%20pong&agent-disable-tools=true&agent-max-iterations=1"
```

- **In process.**

```erlang
{ok, Result} = hb_ao:resolve(
    #{<<"device">> => <<"agent@1.0">>},
    #{<<"path">> => <<"run">>,
      <<"agent-messages">> => [
          #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
      ],
      <<"agent-tools">> => [<<"lookup_data">>, <<"get_arweave_tx">>]},
    NodeOpts).
```

## 10. Conformance (normative checklist)

1. The device exports exactly one key, `run`.
2. `run` reads inputs only from the request message, and never takes
   routing, device names, credentials, the iteration ceiling or policy
   switches from the request or base message.
3. Model calls resolve `completions` on the device named by
   `agent-inference-device` (default `inference@1.0`) with only `path` and a
   JSON `body`.
4. The payload carries `model` only from `agent-model` or
   `agent-default-model`, and `tools`/`tool_choice` only when tools are
   enabled.
5. The effective iteration limit is `min(agent-max-iterations or 10,
   agent-max-iterations-limit or 25)`, with text values accepted; the run
   makes at most that many model calls.
6. Finish reasons are handled exactly as in §4; unknown values end the run
   with `unsupported_finish_reason`.
7. A `length` completion that contains any tool call ends the run with
   `incomplete_response` and executes nothing.
8. A `length` completion with visible text is continued; each continuation
   counts as a model call; partial texts are concatenated and cleared by a
   tool round.
9. The enabled tool set, the tool definitions and the tool lines of the
   system prompt are derived from the same table; `bundle_item` is absent
   unless `agent-allow-bundle` is true; `agent-tools` only narrows the set.
10. Tool calls whose name is not enabled, whose arguments are not a JSON
    object, or which exceed 16 per completion are not executed, and the model
    receives a tool message saying so.
11. Executed tools receive only the argument keys of their schema.
12. `http_request` refuses non-`http`/`https` URLs, `localhost` names and
    non-public address literals unless `agent-http-allow-private` is true,
    and sends requests only through `relay@1.0` or its configured replacement.
13. Tool message contents are valid UTF-8 and bounded as in §5.5.
14. Assistant frames keep `reasoning_content` and `reasoning` text.
15. `agent-tool-choice` applies until the first tool round; later calls use
    `auto`.
16. The result is the base message without `commitments`, with
    `agent-answer` and `agent-iterations`, and with `agent-error` (a code from
    §8) and `agent-error-detail` exactly when the run ended without a final
    answer.

## 11. Out of scope

- Streaming responses, multi-agent coordination and persistent conversation
  storage.
- Caller-defined tools; tools are the built-in table only.
- Finish-reason vocabularies other than OpenAI's; translating other provider
  protocols belongs to the inference device.
- The model runtime, its tool-call parsing and its default model selection.
- The behaviour of the devices this device resolves (`relay@1.0` routing and
  policy, cache and query semantics, Arweave access, bundler dispatch and
  pricing), beyond the request messages listed in §4.
