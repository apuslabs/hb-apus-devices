# `agent@1.0` — tool-using agent loop over an OpenAI-compatible chat model

- **Depends-on:** `inference@1.0` (default model device), `relay@1.0` (`http_request`), `cache@1.0` (`lookup_data`), `query@1.0` (`search_messages`), `arweave@2.9` (`get_arweave_tx`), `bundler@1.0` and `ans104@1.0` (`bundle_item`, only when enabled)
- **Status:** Stable
- **Maintainer:** Apus Network (https://apus.network)

## 1. Overview

`agent@1.0` runs one agent task per request. It sends a conversation to a chat-completion
model, executes the built-in tools the model asks for, appends each result to the
conversation and calls the model again, until the model gives a final answer or an
iteration limit is reached (the ReAct pattern).

The device is pure orchestration and stateless. The model is reached by resolving an
inference device (default `inference@1.0`), every tool is executed by resolving another
device, and the device itself writes nothing to the node's store.

The node operator decides where model calls go, which devices execute tools, which tools
exist and every limit; a request supplies the task and can only narrow what the agent may
do. Each completion's OpenAI `finish_reason` decides the next step.

The reference deployment is `https://hb.apus.network`.

## 2. Concepts & terminology

- **Model call (iteration):** one resolution of `completions` on the inference device; a
  run (one resolution of `run`) counts them in `agent-iterations`.
- **Finish reason:** the `finish_reason` of the first choice of a completion.
- **Tool table:** the built-in tools (§4), each with a name, a description, JSON-schema
  properties, required arguments, a default device and, for `bundle_item`, an enabling
  node option. Tool definitions, prompt lines, accepted argument keys and dispatch are
  derived from it.
- **Enabled tool set:** the tools offered to the model and executable in one run (§4, step
  1). A tool outside this set is never executed.
- **Tool round:** a completion whose `tool_calls` entries are processed; each call is
  answered by one tool message (`role: tool`).
- **Assistant frame:** the assistant message appended after a completion that does not end
  the run.
- **Partial answer:** text collected from `length` completions; it prefixes the final
  answer and is cleared by a tool round.
- **Node option:** a value of the node message, read with `hb_opts:get/3`. Request and
  base messages are never read as node options.

## 3. Device interface

- **Dispatch shape:** explicit keys. The device answers one key, `run`, and `info/1`
  returns `exports => [<<"run">>]`. Any other key is not handled by this device and
  resolves under `message@1.0`.
- **Inputs:** `run` reads its inputs from the request message only. The base message is
  never read for inputs; it is echoed in the result (§4).
- **Invocation:** `GET` or `POST` `/~agent@1.0/run` with the request keys as query
  parameters or body keys, or in process with `hb_ao:resolve/3`.

| Request key | Accepted values | Default | Effect |
|---|---|---|---|
| `agent-user-prompt` | text (§5.6) | `Hello` | User message of the default conversation. |
| `agent-messages` | chat messages (§5.2) | default conversation | The complete initial conversation. |
| `agent-system-prompt` | text (§5.6) | generated (§5.3) | Replaces the generated system prompt. |
| `agent-model` | text (§5.6) | node option `agent-default-model` | `model` field of every model call. |
| `agent-max-iterations` | positive integer (§5.6) | `10` | Maximum model calls, capped by `agent-max-iterations-limit`. |
| `agent-disable-tools` | boolean (§5.6) | `false` | No tool is offered or executable. |
| `agent-tools` | tool names (§5.6) | every enabled tool | Narrows the enabled tool set. |
| `agent-tool-choice` | `auto`, `none`, `required`, or a named-function object | `auto` | `tool_choice` of the model calls (§4, step 5). |

No other request key is read: `agent-api-peer`, `agent-api-path`, `agent-api-key` and
request keys named like the node options below have no effect.

| Node option | Default | Effect |
|---|---|---|
| `agent-inference-device` | `inference@1.0` | Device whose `completions` key serves model calls. |
| `agent-default-model` | none | Model used when the request has no `agent-model`. With neither, model calls carry no `model` field and the runtime chooses. |
| `agent-max-iterations-limit` | `25` | Ceiling of the effective iteration limit. |
| `agent-max-tool-calls-per-completion` | `16` | Tool calls processed per completion. |
| `agent-max-tool-calls-per-run` | `64` | Tool calls processed per run. |
| `agent-max-tool-result-bytes` | `4000` | Tool result text is cut to at most this many bytes, followed by the truncation marker (§5.5). |
| `agent-allow-bundle` | `false` | When true, `bundle_item` is part of the tool table. |
| `agent-http-allow-private` | `false` | When true, `http_request` skips its local-address check (§7). |
| `agent-tool-devices` | none | Map from tool name (`http_request` or `http-request` form) to the device that executes it. |

Numeric and boolean node options are interpreted like request values (§5.6); an invalid
value means the default.

## 4. Resolved keys (normative)

### `run` — run one agent task

- **Reads:** the request keys and node options of §3. The base message is read only to
  build the result.
- **Behaviour:**
  1. **Enabled tool set.** If `agent-disable-tools` is true, the set is empty. Otherwise
     it is the tool table without `bundle_item` unless `agent-allow-bundle` is true,
     narrowed to the names in `agent-tools` when that key is a list or text (§5.6); an
     empty list or empty text selects no tool. Unknown names are ignored, table order is
     kept, and `agent-tools` never adds a tool.
  2. **System prompt.** `agent-system-prompt`, or the prompt generated from the enabled
     tool set (§5.3).
  3. **Initial conversation.** Usable `agent-messages` (§5.2), with a system message
     holding the prompt of step 2 prepended when they contain none. Otherwise a system
     message and a user message holding `agent-user-prompt` (default `Hello`).
  4. **Model.** `agent-model`, else `agent-default-model`, else none.
  5. **Tool choice.** None when the enabled set is empty. Otherwise `agent-tool-choice`
     when it is `auto`, `none` or `required`, or a named-function object (a map or JSON
     text) whose name is in the enabled set, normalized to
     `{"type":"function","function":{"name":N}}`; any other value means `auto`. After a
     tool round, `required` and a named function become `auto`; `auto` and `none` hold for
     the whole run.
  6. **Iteration limit.** `min(R, L)`, where `R` is `agent-max-iterations` (default `10`)
     and `L` is `agent-max-iterations-limit` (default `25`).
  7. **Loop.** Before model call number `i` (from 1), if `i` exceeds the limit the run
     ends with `max_iterations_exceeded` and `agent-iterations` equal to the limit.
     Otherwise the device makes the call (§5.1) and acts on the finish reason as listed
     below. A failed model call or an unusable response ends the run as listed in §8.
- **Returns:** `{ok, Result}` for every run. `Result` is the base message without
  `commitments` and without the four output keys, plus `agent-answer` (the final answer,
  or the sentence of §8 when the run ended with an error) and `agent-iterations` (the
  number of model calls made). Only when the run ended without a final answer, it also has
  `agent-error` (a code from §8) and `agent-error-detail` (a map described in §8).
- **Side effects:** model calls and the effects of executed tools (outbound HTTP, cache
  and Arweave reads, and an Arweave upload when enabled). The device itself writes nothing
  to the store.

#### Finish-reason dispatch

| Finish reason | Condition | Action |
|---|---|---|
| `stop` or `tool_calls` | non-empty `tool_calls` | Tool round: process the calls (*Tool execution*), append the assistant frame and one tool message per call, clear the partial answer, next call. |
| `stop` | no tool calls, answer text or partial answer | Final answer: the partial answer followed by the answer text (§5.4). |
| `stop` | no tool calls, both empty | `incomplete_response`, cause `empty-content`. |
| `tool_calls` | no tool calls | `incomplete_response`, cause `missing-tool-calls`. |
| `length` | any tool call in the message | `incomplete_response`, cause `truncated-tool-call`. Nothing is executed. |
| `length` | empty visible text | `incomplete_response`, cause `empty-content`. |
| `length` | visible text | Append the text to the partial answer, append the assistant frame and the continuation message (§5.3), next call. |
| `content_filter` | none | `content_filtered`. |
| `error` | none | `model_error`. |
| absent or `null` | none | Handled as `stop`. |
| any other value | none | `unsupported_finish_reason`. |

Runtimes report a forced tool call with either `stop` or `tool_calls`; both mean the
generation finished, so the calls are complete. "Any tool call" means a non-empty
`tool_calls` list or a `function_call` object; only `tool_calls` entries are ever
executed. Each continuation counts against the limit.

#### Tool execution

The calls of one completion are processed in order. Under tool choice `none` no call is
executed and each call receives a tool message saying so. Otherwise the first `P` calls
are processed, `P` being the smaller of `agent-max-tool-calls-per-completion` and the
calls left under `agent-max-tool-calls-per-run`; each further call receives a tool message
naming the bound it exceeded. For each processed call:

1. The call is normalized: `id` (a missing or empty id becomes `call_<n>`, `n` being its
   1-based position), function `name`, and `arguments`.
2. A name outside the enabled tool set is not executed; the tool message lists the
   available tools.
3. `arguments` MUST be a JSON object, as JSON text or as an object. Invalid JSON, or valid
   JSON that is not an object, is not executed; the tool message states which, with the
   argument size in bytes and a preview of at most 160 bytes (§5.5).
4. Arguments are filtered to the keys of the tool's schema properties.
5. The executor validates the arguments (a failed validation executes nothing) and
   resolves the tool's device: the `agent-tool-devices` entry for the tool, else the table
   default.
6. A failed device call or an exception becomes a failure message (§8); the run continues.

Calls that were not executed read
`` Tool error: `<name>` was not executed: <reason>. No state was changed. `` and failures
read `` Tool error: `<name>` failed: <reason>. ``

#### Built-in tools

Every executor resolves its device with the base message `{device: <device>}` and the
request message shown, using the node options plus `hashpath => ignore` and
`cache-control => [no-store, no-cache]`.

| Tool | Device and key | Arguments (required in bold) | Request message |
|---|---|---|---|
| `http_request` | `relay@1.0` `call` | **`url`**, `method`, `body`, `content_type` | `path=call`, `target=payload`, `payload={path: url, method[, body, content-type]}` |
| `lookup_data` | `cache@1.0` `read` | **`id`** | `path=read`, `read=id` |
| `search_messages` | `query@1.0` `only` | **`match`**, `return` | `path=only`, `only=match`, `return` |
| `get_arweave_tx` | `arweave@2.9` `tx` | **`id`** | `path=tx`, `tx=id`, `method=GET`, `exclude-data=true` |
| `bundle_item` | `bundler@1.0` `item` | **`data`**, `content_type` | `path=item`, `bundler-subject=item`, `item=<signed item>` |

- `http_request`: `url` MUST be an absolute `http` or `https` URL with a host that passes
  the check of §7. `method` is `GET` (default), `POST`, `PUT` or `DELETE`,
  case-insensitive. A text `body` is sent with `content_type` (default `text/plain`); an
  object or array `body` is sent as JSON (default `application/json`). The result is
  `status: <status>`, a `content-type: <type>` line when present, an empty line and the
  response body. Responses with 4xx or 5xx status are results, not failures.
- `lookup_data`, `get_arweave_tx`: `id` MUST be 43 characters of base64url; not found
  reads `Not found: <id>` and `Transaction not found: <id>`.
- `search_messages`: `match` MUST be a non-empty object whose values are strings, numbers
  or booleans; `return` is `paths` (default), `messages` or `count`; not found reads
  `No matching messages.`
- `bundle_item`: exists only when `agent-allow-bundle` is true. The device builds
  `{data, content-type}` (`content_type`, default `text/plain`), commits it with
  `ans104@1.0` using the node's wallet, and submits it. The result reads
  `Submitted data item <id> to the node's bundler.` when the bundler returns an `id`.

## 5. Data formats & encodings

### 5.1 Model calls

The device resolves `completions` on the inference device with the base message
`{device: <agent-inference-device>}` and the request message
`{path: completions, body: <payload JSON>}`, using the node options plus
`hashpath => ignore` and `cache-control => [no-store, no-cache]`. Nothing else is sent;
the inference device takes its runtime address and credentials from its own node options.
The payload has `messages`, `model` when one is set, and, when the enabled tool set is
non-empty, `tool_choice` and `tools`, with one definition per enabled tool in table order:

```json
{"type": "function", "function": {"name": "lookup_data",
  "description": "Read a message or data item from the node's cache by its 43-character ID.",
  "parameters": {"type": "object", "properties": {"id": {"type": "string",
    "description": "43-character base64url ID."}}, "required": ["id"], "additionalProperties": false}}}
```

The response is read from the call's result: a map whose `status` is 400 or more is a
failure; otherwise its `body` (JSON text or a map) is the response, or the map itself when
it has no `body` but has `choices`. A binary result is JSON text. The response is a
failure when it carries an error envelope (an `error` object or text, or
`"object": "error"`), and unusable when it has no first choice with a `message` object.

### 5.2 Caller conversation

`agent-messages` is usable when it is a non-empty list of objects, a JSON array text, or a
message with the ordinal keys `1` to `N`, every element is an object whose `role` is
`system`, `user`, `assistant` or `tool`, and the list encodes as JSON. Elements are passed
unchanged. Any other value selects the default conversation.

### 5.3 Generated text

The generated system prompt is the preamble
`You are a helpful assistant running on a HyperBEAM node in the AO network.`, a space, and
either `Answer the user's request directly and concisely.` (empty tool set) or the tool
text, with one line per enabled tool in table order:

```text
You can call these tools:
- <name>: <description>
...
Call a tool only when you need information or an action that it provides. When you have enough information, reply with the final answer as plain text and do not call any tool. Keep answers concise.
```

The continuation message after a `length` completion is the user message
`Continue exactly where your previous message stopped. Do not repeat any text you have already written.`

### 5.4 Conversation frames

- **Visible text** of an assistant message: `content` when it is text; the concatenated
  `text` fields of its parts when it is an array; otherwise empty. The **answer text** is
  the visible text, or `refusal` when the visible text is empty and `refusal` is text.
- **Assistant frame:** `role: assistant`, `content` (the visible text, or `null` when
  empty), the normalized `tool_calls` for a tool round (`id`, `type: function`,
  `function: {name, arguments}` with object arguments encoded as JSON text), and
  `reasoning_content` and `reasoning` when the completion carried them as text.
- **Tool message:** `role: tool`, `tool_call_id`, `content` (the result text).

### 5.5 Text bounds

Tool message contents, argument previews and error details are valid UTF-8. At most `B`
bytes of the text are kept, the cut never splits a character, and invalid byte sequences
are replaced with U+FFFD. A shortened text is followed by the marker
`\n[truncated: <kept> of <original> bytes shown]`. `B` is `agent-max-tool-result-bytes`
for tool messages, 160 for argument previews and 512 for error detail text. Tool results
that are not binaries are rendered as JSON after loading links and removing `commitments`
and `priv` keys at every level (Erlang term text when not encodable as JSON).

### 5.6 Value forms

- **Text:** a non-empty binary (invalid UTF-8 sequences replaced with U+FFFD), or a number
  converted to its decimal text. Other values count as absent.
- **Boolean:** `true`, the integer `1`, or the text `true` or `1` (case-insensitive,
  surrounding whitespace ignored). Anything else, including text that is not valid UTF-8,
  is false.
- **Positive integer:** an integer above 0, an integral float of at least 1, or decimal
  text (surrounding whitespace ignored) above 0. HTTP query values arrive as text and are
  accepted. Anything else means the default.
- **Tool names (`agent-tools`):** a list of names, a JSON array text, or comma-separated
  text; names are trimmed and elements that are not valid UTF-8 text are skipped. A list
  or text with no names (such as `[]` or empty text) selects no tool. Values of other
  types leave the tool set unchanged.

## 6. Ordering, freshness & caching

- Model calls are sequential and each sees the full conversation so far. Tool calls run in
  order; their tool messages follow the assistant frame in the same order.
- `run` is not a pure function: it depends on the model, remote HTTP endpoints and cache
  contents. Nested calls are made with `hashpath => ignore` and
  `cache-control => [no-store, no-cache]`. The `run` result carries no cache directive; a
  node that stores results SHOULD exclude `/~agent@1.0/run`.
- No state survives a run. Callers that need memory keep the transcript and send it in
  `agent-messages` on every run.

## 7. Security & authority

- **Routing comes only from node options.** The inference device, the tool devices, the
  default model, every limit and every policy switch are node options. No request key is
  forwarded to the inference device, so a request cannot choose a backend, peer, path or
  credential.
- **Execution authority comes only from the tool table and node options.** `agent-tools`,
  `agent-disable-tools` and `agent-tool-choice` can only restrict tools. A model can only
  run enabled tools, only with object arguments, and only with the keys of the tool's
  schema. Arguments that are not a JSON object, tool calls from a truncated (`length`)
  completion, and tool calls under tool choice `none` are never executed.
- **`http_request` address checks.** Before any network activity the device refuses URLs
  that are not absolute `http`/`https`, hosts named `localhost` or ending in `.localhost`,
  and IP-address literals (short, integer, IPv6 and IPv4-mapped forms included) that are
  not public unicast addresses under HyperBEAM's hostname policy (loopback, private,
  link-local, unspecified and other special-use ranges, and the node's own subnets). Other
  names are not resolved by this device; `relay@1.0` applies DNS-based checks under its
  `relay-block-internal` (default true) and `relay-allowed-hosts` options, so protection
  against names that resolve to private addresses depends on that relay policy.
  `agent-http-allow-private` disables only this device's check; to reach private hosts the
  relay policy MUST also allow them.
- **`bundle_item` writes with the node's identity.** When enabled, data chosen by the
  model is signed with the node's wallet and uploaded permanently, at the node's cost. It
  is disabled by default and cannot be enabled by a request. Tool results are untrusted
  input: fetched content can steer the model, which operators SHOULD weigh before enabling
  writes.
- **Bounded work.** A run makes at most `agent-max-iterations-limit` model calls and
  processes at most `agent-max-tool-calls-per-completion` tool calls per completion and
  `agent-max-tool-calls-per-run` per run. The device bounds the result text handed to the
  model, not the transfer: `relay@1.0` receives the full response body before it is cut,
  so the transfer size depends on the node's relay and network policy.
- **No internal terms in results.** Exceptions and error terms from the inference and tool
  devices are logged on the node and replaced by the generic messages of §8; only error
  envelopes, status codes, error bodies and atom or text reasons are passed on. The result
  echoes the base message (for HTTP, the request) to the caller only.

## 8. Errors

A run that ends without a final answer still returns `{ok, Result}`; `agent-error` holds
one of these codes:

| `agent-error` | `agent-answer` | `agent-error-detail` | Raised when |
|---|---|---|---|
| `max_iterations_exceeded` | `Max iterations reached. Could not complete the task.` | `limit` | The limit is reached before a final answer. |
| `content_filtered` | `The model response was blocked by a content filter.` | `finish-reason` | Finish reason `content_filter`. |
| `incomplete_response` | `The model response was incomplete.` | `finish-reason`, `cause` | See the table in §4. |
| `unsupported_finish_reason` | `The model stopped for an unsupported reason.` | `finish-reason` | Any finish reason not listed in §4. |
| `model_error` | `The model call failed.` | `status`, `message`, `type`, `code`, `finish-reason` (each when known) | The inference call returned an error, a status of 400 or more, or an error envelope, raised an exception, or the finish reason is `error`. |
| `invalid_response` | `The model response could not be parsed.` | `message` | The response is not a JSON object or has no first choice with a message. |

For `model_error`, `message`, `type` and `code` come from the runtime's error envelope;
otherwise `message` is a preview of the error body, the error's `message` text, or an atom
or text reason. An exception gives `the inference call raised an exception`, any other
error term `the inference call failed`.

Tool failures are not run errors: they are reported to the model in tool messages (§4) and
the run continues. The failure reason is the status and body of an error message
(`status <code>: <body>`, or either part alone), an atom or text error reason,
`the device returned an error` for any other error term, or
`the tool raised an exception`.

## 9. Composition

- **Model device.** `agent-inference-device` may name any device whose `completions` key
  accepts an OpenAI chat payload in `body` and returns the response as in §5.1. With
  `inference@1.0`, the runtime address, path and key are that device's node options.
- **Tool devices.** `agent-tool-devices` routes a tool to another device, for example a
  filtering HTTP proxy. The replacement MUST answer the same key with the same request
  message as the default device.
- **Callers.** A Lua process calls `ao.resolve` with `path = "/~agent@1.0/run"` and the
  request keys of §3; Erlang code calls `hb_ao:resolve/3` with the base message
  `{device: agent@1.0}`. Over HTTP:

```bash
curl -s -H 'accept: application/json' \
  "https://hb.apus.network/~agent@1.0/run?agent-user-prompt=Reply%20with%20pong&agent-disable-tools=true&agent-model=google/gemma-4-26B-A4B-it&agent-max-iterations=1"
```

## 10. Conformance (normative checklist)

1. The device exports one key, `run`, which reads inputs only from the request message;
   routing, devices, credentials, limits and policy switches come only from node options.
2. Model calls carry only `path` and a JSON `body`, with `model` only from `agent-model`
   or `agent-default-model`.
3. The iteration limit of §4 step 6 holds for text values too; finish reasons are handled
   exactly as in §4: tool calls of a `stop` or `tool_calls` completion are processed, a
   `length` completion with any tool call executes nothing, and continuations count as
   model calls.
4. The enabled tool set, the tool definitions and the system prompt are derived from one
   table; `bundle_item` is absent unless `agent-allow-bundle` is true; request keys only
   restrict tools.
5. Only enabled tools with JSON-object arguments run, within the per-completion and
   per-run bounds and never under tool choice `none`; executors receive only the argument
   keys of their schema.
6. `http_request` applies the checks of §7 and sends requests only through `relay@1.0` or
   its configured replacement; text bounds follow §5.5; frames keep reasoning text.
7. Every run returns `{ok, Result}`: the base message without `commitments`, with
   `agent-answer` and `agent-iterations`, and with `agent-error` and `agent-error-detail`
   exactly when the run ended without a final answer.

## 11. Out of scope

- Streaming, multi-agent coordination, persistent conversations, caller-defined tools,
  non-OpenAI finish reasons, and the model runtime and its tool-call parsing.
- The behaviour of the devices this device resolves (relay routing and policy, cache and
  query semantics, Arweave access, bundler dispatch and pricing), beyond the request
  messages listed in §4.
