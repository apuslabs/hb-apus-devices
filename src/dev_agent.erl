%%% @doc `agent@1.0': a stateless tool-using agent (a ReAct loop) over an
%%% OpenAI-compatible chat model.
%%%
%%% `run' builds a conversation from the request, asks the node's inference
%%% device for a chat completion, executes the built-in tools that the model
%%% calls, appends the observations and repeats until the model answers or the
%%% iteration limit is reached. The `finish_reason' of each completion decides
%%% the next step: the tool calls of a finished completion (`stop' or
%%% `tool_calls') are executed, `stop' without tool calls answers, `length'
%%% continues a truncated answer, and every other value ends the run with an
%%% error code.
%%%
%%% Authority boundaries:
%%% <ul>
%%%   <li>The inference device, the tool executor devices and every policy
%%%       switch are node options. Request and base messages never select a
%%%       backend, peer, credential, device or path.</li>
%%%   <li>The request may narrow the built-in tool set (`agent-tools') but
%%%       never widen it. `bundle_item' exists only when the operator sets
%%%       `agent-allow-bundle'.</li>
%%%   <li>A tool runs only when its arguments are a JSON object, and only the
%%%       argument keys declared in its schema reach its executor.</li>
%%% </ul>
%%%
%%% The normative description is `docs/spec/agent.md'.
-module(dev_agent).
-implements(<<"agent@1.0">>).
-specification("docs/spec/agent.md").
-export([info/1, run/3]).
-include_lib("hb/include/hb.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% Node option defaults.
-define(DEFAULT_INFERENCE_DEVICE, <<"inference@1.0">>).
-define(DEFAULT_MAX_ITERATIONS_LIMIT, 25).
-define(DEFAULT_MAX_TOOL_RESULT_BYTES, 4000).
-define(DEFAULT_MAX_TOOL_CALLS_PER_COMPLETION, 16).
-define(DEFAULT_MAX_TOOL_CALLS_PER_RUN, 64).

%% Request defaults.
-define(DEFAULT_USER_PROMPT, <<"Hello">>).
-define(DEFAULT_MAX_ITERATIONS, 10).

%% Constant bounds.
-define(PREVIEW_BYTES, 160).
-define(MAX_DETAIL_BYTES, 512).

%% Keys this device writes into its result. Values with these names in the
%% base message are replaced, never echoed.
-define(OUTPUT_KEYS, [
    <<"agent-answer">>,
    <<"agent-iterations">>,
    <<"agent-error">>,
    <<"agent-error-detail">>
]).

-define(MESSAGE_ROLES, [<<"system">>, <<"user">>, <<"assistant">>, <<"tool">>]).
-define(TOOL_CHOICE_MODES, [<<"auto">>, <<"none">>, <<"required">>]).
-define(HTTP_METHODS, [<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>]).
-define(SEARCH_RETURNS, [<<"paths">>, <<"messages">>, <<"count">>]).

-define(PROMPT_PREAMBLE,
    <<"You are a helpful assistant running on a HyperBEAM node in the AO "
      "network.">>).
-define(INFERENCE_FAILED, <<"the inference call failed">>).
-define(TOOL_EXCEPTION, <<"the tool raised an exception">>).
-define(DEVICE_FAILED, <<"the device returned an error">>).
-define(CONTINUE_PROMPT,
    <<"Continue exactly where your previous message stopped. Do not repeat "
      "any text you have already written.">>).

%%%===================================================================
%%% Device API
%%%===================================================================

%% @doc The device exposes a single key, `run'.
-spec info(term()) -> #{ exports := [binary()] }.
info(_) ->
    #{ exports => [<<"run">>] }.

%% @doc Run one agent task and return the base message with the outcome.
%% Inputs are read from the request message only; the base message is echoed
%% in the result (without its commitments) and never consulted.
-spec run(
    #{ _ => _ },
    #{
        'agent-user-prompt' => _,
        'agent-messages' => _,
        'agent-system-prompt' => _,
        'agent-model' => _,
        'agent-max-iterations' => _,
        'agent-disable-tools' => _,
        'agent-tools' => _,
        'agent-tool-choice' => _,
        _ => _
    },
    map()
) -> {ok, #{
        'agent-answer' := binary(),
        'agent-iterations' := pos_integer(),
        'agent-error' => binary(),
        'agent-error-detail' => #{ _ => _ },
        _ => _
    }}.
run(Base, Req, Opts) ->
    Tools = enabled_tools(Req, Opts),
    State = #{
        base => Base,
        opts => Opts,
        tools => Tools,
        model => model(Req, Opts),
        tool_choice => initial_tool_choice(Req, Tools, Opts),
        max_iterations => max_iterations(Req, Opts),
        max_result_bytes =>
            node_limit(
                <<"agent-max-tool-result-bytes">>,
                ?DEFAULT_MAX_TOOL_RESULT_BYTES,
                Opts
            ),
        max_calls_per_completion =>
            node_limit(
                <<"agent-max-tool-calls-per-completion">>,
                ?DEFAULT_MAX_TOOL_CALLS_PER_COMPLETION,
                Opts
            ),
        max_calls_per_run =>
            node_limit(
                <<"agent-max-tool-calls-per-run">>,
                ?DEFAULT_MAX_TOOL_CALLS_PER_RUN,
                Opts
            ),
        tool_calls_made => 0,
        messages =>
            initial_messages(Req, system_prompt(Req, Tools, Opts), Opts),
        iteration => 1,
        partial => <<>>
    },
    loop(State).

%%%===================================================================
%%% Loop
%%%===================================================================

%% @doc One model call per iteration. The iteration counter is the number of
%% the next model call; the run stops before a call that would exceed the
%% limit.
loop(State = #{ iteration := Iteration, max_iterations := Max })
        when Iteration > Max ->
    ?event(agent, {max_iterations_reached, Max}),
    finish_error(
        <<"max_iterations_exceeded">>,
        #{ <<"limit">> => Max },
        Max,
        State
    );
loop(State = #{ iteration := Iteration }) ->
    ?event(agent, {model_call, Iteration}),
    case call_model(State) of
        {ok, Response} -> step(parse_response(Response), State);
        {error, Code, Detail} -> finish_error(Code, Detail, Iteration, State)
    end.

%% @doc Apply the outcome of one completion.
step({answer, <<>>}, State = #{ iteration := Iteration, partial := <<>> }) ->
    ?event(agent, {empty_answer, Iteration}),
    {error, Code, Detail} = incomplete(<<"stop">>, <<"empty-content">>),
    finish_error(Code, Detail, Iteration, State);
step({answer, Text}, State = #{ iteration := Iteration, partial := Partial }) ->
    ?event(agent, {final_answer, Iteration}),
    finish_answer(<<Partial/binary, Text/binary>>, Iteration, State);
step({tool_calls, Frame, Calls}, State) ->
    #{ iteration := Iteration, messages := Messages, tool_calls_made := Made } =
        State,
    ?event(agent, {tool_calls, Iteration, length(Calls)}),
    {Results, Processed} = execute_tool_calls(Calls, State),
    loop(State#{
        messages := Messages ++ [Frame | Results],
        iteration := Iteration + 1,
        partial := <<>>,
        tool_choice := tool_choice_after_tools(State),
        tool_calls_made := Made + Processed
    });
step({continue, Frame, Text}, State) ->
    #{ iteration := Iteration, messages := Messages, partial := Partial } =
        State,
    ?event(agent, {continue_truncated_answer, Iteration}),
    loop(State#{
        messages :=
            Messages ++
                [Frame, #{ <<"role">> => <<"user">>,
                           <<"content">> => ?CONTINUE_PROMPT }],
        iteration := Iteration + 1,
        partial := <<Partial/binary, Text/binary>>
    });
step({error, Code, Detail}, State = #{ iteration := Iteration }) ->
    ?event(agent, {run_failed, Code, Iteration}),
    finish_error(Code, Detail, Iteration, State).

%% @doc `required' and a named function apply until the first tool round;
%% repeating them would force a tool call on every completion, so later
%% calls use `auto'. `auto' and `none' are kept for the whole run.
tool_choice_after_tools(#{ tool_choice := Choice })
        when Choice =:= undefined; Choice =:= <<"auto">>; Choice =:= <<"none">> ->
    Choice;
tool_choice_after_tools(_) ->
    <<"auto">>.

finish_answer(Answer, Iterations, #{ base := Base, opts := Opts }) ->
    {ok, (result_base(Base, Opts))#{
        <<"agent-answer">> => Answer,
        <<"agent-iterations">> => Iterations
    }}.

finish_error(Code, Detail, Iterations, #{ base := Base, opts := Opts }) ->
    {ok, (result_base(Base, Opts))#{
        <<"agent-answer">> => error_answer(Code),
        <<"agent-iterations">> => Iterations,
        <<"agent-error">> => Code,
        <<"agent-error-detail">> => Detail
    }}.

%% @doc The result echoes the base message. Its commitments do not cover the
%% result and are removed, and output keys it carries are replaced.
result_base(Base, Opts) ->
    maps:without(?OUTPUT_KEYS, hb_message:uncommitted(Base, Opts)).

error_answer(<<"max_iterations_exceeded">>) ->
    <<"Max iterations reached. Could not complete the task.">>;
error_answer(<<"content_filtered">>) ->
    <<"The model response was blocked by a content filter.">>;
error_answer(<<"incomplete_response">>) ->
    <<"The model response was incomplete.">>;
error_answer(<<"unsupported_finish_reason">>) ->
    <<"The model stopped for an unsupported reason.">>;
error_answer(<<"invalid_response">>) ->
    <<"The model response could not be parsed.">>;
error_answer(<<"model_error">>) ->
    <<"The model call failed.">>.

%%%===================================================================
%%% Request inputs
%%%===================================================================

%% @doc Read a key from the request message, loading it if it is a link.
req(Key, Req, Opts) ->
    hb_maps:get(Key, Req, not_found, Opts).

%% @doc `agent-model', then node option `agent-default-model'. Without
%% either, the payload has no `model' field and the runtime chooses.
model(Req, Opts) ->
    case nonempty_text(req(<<"agent-model">>, Req, Opts)) of
        {ok, Model} -> Model;
        error ->
            case nonempty_text(
                    hb_opts:get(<<"agent-default-model">>, not_found, Opts)) of
                {ok, Model} -> Model;
                error -> undefined
            end
    end.

%% @doc The effective iteration limit: the requested value (or the default)
%% capped by the operator ceiling.
max_iterations(Req, Opts) ->
    Limit =
        node_limit(
            <<"agent-max-iterations-limit">>,
            ?DEFAULT_MAX_ITERATIONS_LIMIT,
            Opts
        ),
    Requested =
        case positive_int(req(<<"agent-max-iterations">>, Req, Opts)) of
            {ok, N} -> N;
            error -> ?DEFAULT_MAX_ITERATIONS
        end,
    min(Requested, Limit).

%% @doc A positive-integer node option, or its default when the option is
%% absent or invalid.
node_limit(Key, Default, Opts) ->
    case positive_int(hb_opts:get(Key, not_found, Opts)) of
        {ok, N} -> N;
        error -> Default
    end.

%% @doc The built-in tools offered in this run: the operator-enabled table,
%% narrowed by `agent-tools', or nothing when `agent-disable-tools' is set.
enabled_tools(Req, Opts) ->
    case truthy(req(<<"agent-disable-tools">>, Req, Opts)) of
        true -> [];
        false ->
            Available =
                [
                    Tool
                ||
                    Tool = #{ requires := Gate } <- tool_table(),
                    gate_open(Gate, Opts)
                ],
            case requested_tool_names(req(<<"agent-tools">>, Req, Opts)) of
                all -> Available;
                Names ->
                    [
                        Tool
                    ||
                        Tool = #{ name := Name } <- Available,
                        lists:member(Name, Names)
                    ]
            end
    end.

gate_open(none, _Opts) -> true;
gate_open(Option, Opts) -> truthy(hb_opts:get(Option, false, Opts)).

%% @doc `agent-tools' as a list of names, a JSON array, or a comma-separated
%% text. Elements that are not valid UTF-8 text are skipped, so an empty
%% list or text selects no tool. Any other value leaves the set unchanged.
requested_tool_names(not_found) -> all;
requested_tool_names(List) when is_list(List) ->
    [Name || Element <- List, {ok, Name} <- [trimmed(Element)]];
requested_tool_names(Bin) when is_binary(Bin) ->
    case decode_json(Bin) of
        {ok, List} when is_list(List) -> requested_tool_names(List);
        _ ->
            [
                Name
            ||
                Part <- binary:split(Bin, <<",">>, [global]),
                {ok, Name} <- [trimmed(Part)],
                Name =/= <<>>
            ]
    end;
requested_tool_names(_) -> all.

%% @doc `agent-tool-choice' when tools are offered: `auto', `none',
%% `required', or a named function object (map or JSON text) that names an
%% enabled tool. Any other value means `auto'.
initial_tool_choice(_Req, [], _Opts) -> undefined;
initial_tool_choice(Req, Tools, Opts) ->
    case req(<<"agent-tool-choice">>, Req, Opts) of
        Mode when is_binary(Mode) ->
            case lists:member(Mode, ?TOOL_CHOICE_MODES) of
                true -> Mode;
                false ->
                    case decode_json(Mode) of
                        {ok, Choice} -> named_tool_choice(Choice, Tools);
                        error -> <<"auto">>
                    end
            end;
        Choice -> named_tool_choice(Choice, Tools)
    end.

named_tool_choice(#{ <<"type">> := <<"function">>,
                     <<"function">> := #{ <<"name">> := Name } }, Tools)
        when is_binary(Name) ->
    case lists:member(Name, [ToolName || #{ name := ToolName } <- Tools]) of
        true ->
            #{ <<"type">> => <<"function">>,
               <<"function">> => #{ <<"name">> => Name } };
        false ->
            <<"auto">>
    end;
named_tool_choice(_Choice, _Tools) ->
    <<"auto">>.

%% @doc `agent-system-prompt', or the prompt generated from the tool set.
system_prompt(Req, Tools, Opts) ->
    case nonempty_text(req(<<"agent-system-prompt">>, Req, Opts)) of
        {ok, Prompt} -> Prompt;
        error -> default_system_prompt(Tools)
    end.

default_system_prompt([]) ->
    <<?PROMPT_PREAMBLE/binary,
      " Answer the user's request directly and concisely.">>;
default_system_prompt(Tools) ->
    Lines =
        << <<"- ", Name/binary, ": ", Description/binary, "\n">>
        || #{ name := Name, description := Description } <- Tools >>,
    <<?PROMPT_PREAMBLE/binary, " You can call these tools:\n", Lines/binary,
      "Call a tool only when you need information or an action that it "
      "provides. When you have enough information, reply with the final "
      "answer as plain text and do not call any tool. Keep answers "
      "concise.">>.

%% @doc The caller's `agent-messages' when they are usable, otherwise the
%% system prompt followed by `agent-user-prompt'.
initial_messages(Req, SystemPrompt, Opts) ->
    System = #{ <<"role">> => <<"system">>, <<"content">> => SystemPrompt },
    case caller_messages(req(<<"agent-messages">>, Req, Opts), Opts) of
        {ok, Messages} ->
            case lists:any(fun is_system_message/1, Messages) of
                true -> Messages;
                false -> [System | Messages]
            end;
        error ->
            Prompt =
                case nonempty_text(req(<<"agent-user-prompt">>, Req, Opts)) of
                    {ok, Text} -> Text;
                    error -> ?DEFAULT_USER_PROMPT
                end,
            [System, #{ <<"role">> => <<"user">>, <<"content">> => Prompt }]
    end.

is_system_message(#{ <<"role">> := <<"system">> }) -> true;
is_system_message(_) -> false.

%% @doc Accept a list of messages, a JSON array, or a message with ordinal
%% keys (`1', `2', ...). Every element must be an object with a known
%% `role', and the list must encode as JSON.
caller_messages(not_found, _Opts) -> error;
caller_messages(Bin, Opts) when is_binary(Bin) ->
    case decode_json(Bin) of
        {ok, List} when is_list(List) -> caller_messages(List, Opts);
        _ -> error
    end;
caller_messages(List, Opts) when is_list(List), List =/= [] ->
    Loaded = try hb_cache:ensure_all_loaded(List, Opts) catch _:_ -> List end,
    Valid =
        lists:all(
            fun(#{ <<"role">> := Role }) -> lists:member(Role, ?MESSAGE_ROLES);
               (_) -> false
            end,
            Loaded
        ),
    case Valid andalso json_encodable(Loaded) of
        true -> {ok, Loaded};
        false -> error
    end;
caller_messages(Map, Opts) when is_map(Map), map_size(Map) > 0 ->
    case ordinal_values(Map) of
        {ok, List} -> caller_messages(List, Opts);
        error -> error
    end;
caller_messages(_, _Opts) -> error.

ordinal_values(Map) ->
    try
        Indexed =
            [{binary_to_integer(hb_util:bin(K)), V} || {K, V} <- maps:to_list(Map)],
        Sorted = lists:keysort(1, Indexed),
        case [I || {I, _} <- Sorted] =:= lists:seq(1, length(Sorted)) of
            true -> {ok, [V || {_, V} <- Sorted]};
            false -> error
        end
    catch _:_ -> error
    end.

%%%===================================================================
%%% Model calls
%%%===================================================================

%% @doc The OpenAI chat-completions payload for the next call.
request_payload(State) ->
    #{ messages := Messages, tools := Tools,
       tool_choice := Choice, model := Model } = State,
    WithMessages = #{ <<"messages">> => Messages },
    WithModel =
        case Model of
            undefined -> WithMessages;
            _ -> WithMessages#{ <<"model">> => Model }
        end,
    case Tools of
        [] -> WithModel;
        _ ->
            WithModel#{
                <<"tools">> => [tool_definition(Tool) || Tool <- Tools],
                <<"tool_choice">> => Choice
            }
    end.

%% @doc Resolve `completions' on the inference device named by the node
%% option `agent-inference-device'. Only `path' and the JSON `body' are sent;
%% routing and credentials are the inference device's node options.
call_model(State = #{ opts := Opts }) ->
    Device =
        hb_opts:get(<<"agent-inference-device">>, ?DEFAULT_INFERENCE_DEVICE, Opts),
    try
        Body = hb_json:encode(request_payload(State)),
        hb_ao:resolve(
            #{ <<"device">> => Device },
            #{ <<"path">> => <<"completions">>, <<"body">> => Body },
            no_cache(Opts)
        )
    of
        {ok, Result} -> model_result(Result, Opts);
        {error, Reason} -> {error, <<"model_error">>, error_detail(Reason, Opts)};
        Other -> {error, <<"model_error">>, error_detail(Other, Opts)}
    catch
        Class:Reason ->
            ?event(agent, {inference_exception, Class, Reason}),
            {error, <<"model_error">>,
                #{ <<"message">> => <<"the inference call raised an exception">> }}
    end.

%% @doc Interpret the inference device's result message.
model_result(Result, Opts) when is_map(Result) ->
    case status_code(hb_maps:get(<<"status">>, Result, 200, Opts)) of
        Status when is_integer(Status), Status >= 400 ->
            {error, <<"model_error">>, error_detail(Result, Opts)};
        _ ->
            case hb_maps:get(<<"body">>, Result, not_found, Opts) of
                not_found when is_map_key(<<"choices">>, Result) -> {ok, Result};
                Body -> decode_response(Body)
            end
    end;
model_result(Body, _Opts) when is_binary(Body) ->
    decode_response(Body);
model_result(_Other, _Opts) ->
    {error, <<"invalid_response">>,
        #{ <<"message">> => <<"the inference result is not a message">> }}.

decode_response(Response) when is_map(Response) ->
    {ok, Response};
decode_response(Body) when is_binary(Body) ->
    case decode_json(Body) of
        {ok, Response} when is_map(Response) -> {ok, Response};
        _ ->
            {error, <<"invalid_response">>,
                #{ <<"message">> => <<"the response body is not a JSON object">> }}
    end;
decode_response(_) ->
    {error, <<"invalid_response">>,
        #{ <<"message">> => <<"the response has no body">> }}.

%% @doc Classify a decoded chat completion.
parse_response(Response) ->
    case error_envelope(Response) of
        none -> parse_choices(Response);
        Detail -> {error, <<"model_error">>, Detail}
    end.

parse_choices(Response) ->
    case maps:get(<<"choices">>, Response, []) of
        [Choice | _] when is_map(Choice) -> parse_choice(Choice);
        _ ->
            {error, <<"invalid_response">>,
                #{ <<"message">> => <<"the response has no choices">> }}
    end.

parse_choice(Choice) ->
    case maps:get(<<"message">>, Choice, not_found) of
        Message when is_map(Message) ->
            dispatch(finish_reason(Choice, Message), Message);
        _ ->
            {error, <<"invalid_response">>,
                #{ <<"message">> => <<"the first choice has no message">> }}
    end.

%% @doc A missing or null `finish_reason' is handled as `stop'.
finish_reason(Choice, _Message) ->
    case maps:get(<<"finish_reason">>, Choice, null) of
        null -> <<"stop">>;
        Reason when is_binary(Reason) -> Reason;
        Other -> describe(Other)
    end.

%% @doc A finished completion (`stop' or `tool_calls') with tool calls is a
%% tool round: runtimes report a forced tool call with either value.
dispatch(<<"stop">>, Message) ->
    case tool_call_list(Message) of
        [] -> {answer, answer_text(Message)};
        RawCalls -> tool_round(Message, RawCalls)
    end;
dispatch(<<"tool_calls">>, Message) ->
    case tool_call_list(Message) of
        [] -> incomplete(<<"tool_calls">>, <<"missing-tool-calls">>);
        RawCalls -> tool_round(Message, RawCalls)
    end;
dispatch(<<"length">>, Message) ->
    case {has_tool_call(Message), content_text(Message)} of
        {true, _} -> incomplete(<<"length">>, <<"truncated-tool-call">>);
        {false, <<>>} -> incomplete(<<"length">>, <<"empty-content">>);
        {false, Text} -> {continue, assistant_frame(Message, #{}), Text}
    end;
dispatch(<<"content_filter">>, _Message) ->
    {error, <<"content_filtered">>,
        #{ <<"finish-reason">> => <<"content_filter">> }};
dispatch(<<"error">>, _Message) ->
    {error, <<"model_error">>, #{ <<"finish-reason">> => <<"error">> }};
dispatch(Other, _Message) ->
    {error, <<"unsupported_finish_reason">>,
        #{ <<"finish-reason">> => bound_text(Other, ?MAX_DETAIL_BYTES) }}.

tool_round(Message, RawCalls) ->
    Calls = normalize_tool_calls(RawCalls),
    Frame =
        assistant_frame(
            Message,
            #{ <<"tool_calls">> => [frame_call(Call) || Call <- Calls] }
        ),
    {tool_calls, Frame, Calls}.

incomplete(FinishReason, Cause) ->
    {error, <<"incomplete_response">>,
        #{ <<"finish-reason">> => FinishReason, <<"cause">> => Cause }}.

tool_call_list(Message) ->
    case maps:get(<<"tool_calls">>, Message, null) of
        Calls when is_list(Calls) -> Calls;
        _ -> []
    end.

%% @doc Any tool call, complete or not, including the single-call
%% `function_call' form.
has_tool_call(Message) ->
    tool_call_list(Message) =/= [] orelse
        is_map(maps:get(<<"function_call">>, Message, null)).

%% @doc The visible text of an assistant message. Array content keeps its
%% text parts.
content_text(Message) ->
    case maps:get(<<"content">>, Message, null) of
        Text when is_binary(Text) -> Text;
        Parts when is_list(Parts) ->
            << <<Text/binary>>
            || #{ <<"text">> := Text } <- Parts, is_binary(Text) >>;
        _ -> <<>>
    end.

%% @doc The final answer: the content, or the `refusal' text when the
%% content is empty.
answer_text(Message) ->
    case content_text(Message) of
        <<>> ->
            case maps:get(<<"refusal">>, Message, null) of
                Refusal when is_binary(Refusal) -> Refusal;
                _ -> <<>>
            end;
        Text -> Text
    end.

%% @doc The assistant frame appended to the history. Reasoning fields are
%% kept so that reasoning models can continue after tool results.
assistant_frame(Message, Extra) ->
    Content =
        case content_text(Message) of
            <<>> -> null;
            Text -> Text
        end,
    Reasoning =
        maps:filter(
            fun(_Key, Value) -> is_binary(Value) end,
            maps:with([<<"reasoning_content">>, <<"reasoning">>], Message)
        ),
    maps:merge(
        Reasoning,
        Extra#{ <<"role">> => <<"assistant">>, <<"content">> => Content }
    ).

normalize_tool_calls(RawCalls) ->
    lists:zipwith(
        fun normalize_tool_call/2,
        RawCalls,
        lists:seq(1, length(RawCalls))
    ).

normalize_tool_call(Call, Index) when is_map(Call) ->
    Function =
        case maps:get(<<"function">>, Call, #{}) of
            F when is_map(F) -> F;
            _ -> #{}
        end,
    #{
        id =>
            case maps:get(<<"id">>, Call, null) of
                Id when is_binary(Id), Id =/= <<>> -> Id;
                _ -> generated_call_id(Index)
            end,
        name =>
            case maps:get(<<"name">>, Function, null) of
                Name when is_binary(Name) -> Name;
                _ -> <<>>
            end,
        arguments => maps:get(<<"arguments">>, Function, <<>>)
    };
normalize_tool_call(_Call, Index) ->
    #{ id => generated_call_id(Index), name => <<>>, arguments => <<>> }.

generated_call_id(Index) ->
    <<"call_", (integer_to_binary(Index))/binary>>.

frame_call(#{ id := Id, name := Name, arguments := Arguments }) ->
    #{
        <<"id">> => Id,
        <<"type">> => <<"function">>,
        <<"function">> => #{
            <<"name">> => Name,
            <<"arguments">> => arguments_text(Arguments)
        }
    }.

arguments_text(Arguments) when is_binary(Arguments) -> Arguments;
arguments_text(Arguments) ->
    try hb_json:encode(Arguments) catch _:_ -> <<>> end.

%% @doc The detail of an OpenAI-style error envelope (an `error' object or
%% text, or `"object": "error"'), or `none'.
error_envelope(#{ <<"error">> := Error }) when is_map(Error) ->
    error_fields(Error);
error_envelope(#{ <<"error">> := Error }) when is_binary(Error) ->
    #{ <<"message">> => bound_text(Error, ?MAX_DETAIL_BYTES) };
error_envelope(Response = #{ <<"object">> := <<"error">> }) ->
    error_fields(Response);
error_envelope(_) ->
    none.

error_fields(Map) ->
    Fields =
        maps:from_list(
            [
                {Key, detail_value(Value)}
            ||
                Key <- [<<"message">>, <<"type">>, <<"code">>],
                Value <- [maps:get(Key, Map, null)],
                is_binary(Value) orelse is_integer(Value)
            ]
        ),
    case map_size(Fields) of
        0 -> #{ <<"message">> => <<"the response carries an error">> };
        _ -> Fields
    end.

detail_value(Value) when is_binary(Value) -> bound_text(Value, ?MAX_DETAIL_BYTES);
detail_value(Value) -> Value.

%% @doc Describe a failed inference call: its status and the runtime's error
%% message when available. Other error terms are logged, not returned.
error_detail(Reason, Opts) when is_map(Reason) ->
    ?event(agent, {inference_error, Reason}),
    Status =
        case status_code(hb_maps:get(<<"status">>, Reason, not_found, Opts)) of
            Code when is_integer(Code) -> #{ <<"status">> => Code };
            _ -> #{}
        end,
    FromBody =
        case hb_maps:get(<<"body">>, Reason, not_found, Opts) of
            Body when is_binary(Body), Body =/= <<>> ->
                case decode_json(Body) of
                    {ok, Decoded} when is_map(Decoded) ->
                        case error_envelope(Decoded) of
                            none -> body_message(Body);
                            Fields -> Fields
                        end;
                    _ -> body_message(Body)
                end;
            Body when is_map(Body) ->
                case error_envelope(Body) of
                    none -> #{};
                    Fields -> Fields
                end;
            _ -> #{}
        end,
    Message =
        case {FromBody, hb_maps:get(<<"message">>, Reason, not_found, Opts)} of
            {#{ <<"message">> := _ }, _} -> #{};
            {_, Text} when is_binary(Text) ->
                #{ <<"message">> => bound_text(Text, ?MAX_DETAIL_BYTES) };
            _ when map_size(Status) > 0 -> #{};
            _ -> #{ <<"message">> => ?INFERENCE_FAILED }
        end,
    maps:merge(maps:merge(Status, FromBody), Message);
error_detail(Reason, _Opts) ->
    ?event(agent, {inference_error, Reason}),
    #{ <<"message">> => reason_text(Reason, ?INFERENCE_FAILED) }.

body_message(Body) ->
    #{ <<"message">> => bound_text(Body, ?MAX_DETAIL_BYTES) }.

status_code(Code) when is_integer(Code) -> Code;
status_code(Code) when is_binary(Code) ->
    try binary_to_integer(Code) catch _:_ -> undefined end;
status_code(_) -> undefined.

%%%===================================================================
%%% Tools
%%%===================================================================

%% @doc The built-in tool table. Each entry is the single source of a tool's
%% name, description (used in the system prompt and the tool definition),
%% JSON schema properties (whose keys are the only arguments passed to the
%% executor), required arguments, default executor device, the node option
%% that must be true for the tool to exist, and the executor function.
tool_table() ->
    [
        #{
            name => <<"http_request">>,
            description =>
                <<"Make an HTTP request to a public http or https URL and "
                  "return the response status, content type and body.">>,
            properties => #{
                <<"url">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"Absolute http or https URL.">>
                },
                <<"method">> => #{
                    <<"type">> => <<"string">>,
                    <<"enum">> => ?HTTP_METHODS,
                    <<"description">> => <<"HTTP method. Defaults to GET.">>
                },
                <<"body">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"Request body.">>
                },
                <<"content_type">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> =>
                        <<"Content type of the body. Defaults to text/plain.">>
                }
            },
            required => [<<"url">>],
            device => <<"relay@1.0">>,
            requires => none,
            executor => fun http_request/3
        },
        #{
            name => <<"lookup_data">>,
            description =>
                <<"Read a message or data item from the node's cache by its "
                  "43-character ID.">>,
            properties => #{
                <<"id">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"43-character base64url ID.">>
                }
            },
            required => [<<"id">>],
            device => <<"cache@1.0">>,
            requires => none,
            executor => fun lookup_data/3
        },
        #{
            name => <<"search_messages">>,
            description =>
                <<"Search the node's cache for messages whose keys have the "
                  "given values.">>,
            properties => #{
                <<"match">> => #{
                    <<"type">> => <<"object">>,
                    <<"description">> =>
                        <<"Keys and the values they must have. Values are "
                          "strings, numbers or booleans.">>
                },
                <<"return">> => #{
                    <<"type">> => <<"string">>,
                    <<"enum">> => ?SEARCH_RETURNS,
                    <<"description">> =>
                        <<"paths (default), messages, or count.">>
                }
            },
            required => [<<"match">>],
            device => <<"query@1.0">>,
            requires => none,
            executor => fun search_messages/3
        },
        #{
            name => <<"get_arweave_tx">>,
            description =>
                <<"Fetch an Arweave transaction header by its 43-character "
                  "transaction ID.">>,
            properties => #{
                <<"id">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"Arweave transaction ID.">>
                }
            },
            required => [<<"id">>],
            device => <<"arweave@2.9">>,
            requires => none,
            executor => fun get_arweave_tx/3
        },
        #{
            name => <<"bundle_item">>,
            description =>
                <<"Permanently store data on Arweave: the node signs it as a "
                  "data item with its own wallet and submits it to its "
                  "bundler.">>,
            properties => #{
                <<"data">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"The data to store.">>
                },
                <<"content_type">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> =>
                        <<"Content type of the data. Defaults to text/plain.">>
                }
            },
            required => [<<"data">>],
            device => <<"bundler@1.0">>,
            requires => <<"agent-allow-bundle">>,
            executor => fun bundle_item/3
        }
    ].

%% @doc The OpenAI tool definition generated from a table entry.
tool_definition(#{ name := Name, description := Description,
                   properties := Properties, required := Required }) ->
    #{
        <<"type">> => <<"function">>,
        <<"function">> => #{
            <<"name">> => Name,
            <<"description">> => Description,
            <<"parameters">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => Properties,
                <<"required">> => Required,
                <<"additionalProperties">> => false
            }
        }
    }.

%% @doc The device a tool resolves: node option `agent-tool-devices' (a map
%% from tool name to device), or the table default.
tool_device(#{ name := Name, device := Default }, Opts) ->
    case hb_opts:get(<<"agent-tool-devices">>, #{}, Opts) of
        Devices when is_map(Devices) ->
            Hyphenated = binary:replace(Name, <<"_">>, <<"-">>, [global]),
            case maps:get(Name, Devices, maps:get(Hyphenated, Devices, not_found)) of
                not_found -> Default;
                Device -> Device
            end;
        _ -> Default
    end.

%% @doc Process the tool calls of one completion, in order, and return
%% their tool messages and the number of calls processed. Calls beyond the
%% per-completion or per-run bound are answered without being executed;
%% under tool choice `none' no call is executed.
execute_tool_calls(Calls, State = #{ tool_choice := <<"none">> }) ->
    #{ max_result_bytes := MaxBytes } = State,
    {
        [
            tool_message(
                Call,
                rejected_text(Name, <<"the tool choice of this run is none">>),
                MaxBytes
            )
        ||
            Call = #{ name := Name } <- Calls
        ],
        0
    };
execute_tool_calls(Calls, State) ->
    #{
        max_result_bytes := MaxBytes,
        max_calls_per_completion := PerCompletion,
        max_calls_per_run := PerRun,
        tool_calls_made := Made
    } = State,
    Left = PerRun - Made,
    Count = lists:min([length(Calls), PerCompletion, Left]),
    {Processed, Skipped} = lists:split(Count, Calls),
    Why =
        case Left < PerCompletion of
            true ->
                <<"a run may make at most ",
                  (integer_to_binary(PerRun))/binary, " tool calls">>;
            false ->
                <<"a completion may request at most ",
                  (integer_to_binary(PerCompletion))/binary, " tool calls">>
        end,
    {
        [
            tool_message(Call, execute_tool_call(Call, State), MaxBytes)
        ||
            Call <- Processed
        ] ++
        [
            tool_message(Call, rejected_text(Name, Why), MaxBytes)
        ||
            Call = #{ name := Name } <- Skipped
        ],
        Count
    }.

tool_message(#{ id := Id }, Content, MaxBytes) ->
    #{
        <<"role">> => <<"tool">>,
        <<"tool_call_id">> => Id,
        <<"content">> => bound_text(Content, MaxBytes)
    }.

%% @doc Execute one call: only enabled tools, only JSON-object arguments,
%% only declared argument keys.
execute_tool_call(#{ name := Name, arguments := Raw }, State) ->
    #{ tools := Tools, opts := Opts } = State,
    case [Tool || Tool = #{ name := ToolName } <- Tools, ToolName =:= Name] of
        [] ->
            rejected_text(
                Name,
                <<"no tool with this name is available. Available tools: ",
                  (tool_names(Tools))/binary>>
            );
        [Tool | _] ->
            case decode_arguments(Raw) of
                {ok, Args} ->
                    #{ properties := Properties } = Tool,
                    invoke(Tool, maps:with(maps:keys(Properties), Args), Opts);
                {error, Why} ->
                    rejected_text(Name, Why)
            end
    end.

tool_names([]) -> <<"none">>;
tool_names(Tools) ->
    iolist_to_binary(lists:join(<<", ">>, [Name || #{ name := Name } <- Tools])).

decode_arguments(Args) when is_map(Args) -> {ok, Args};
decode_arguments(Raw) when is_binary(Raw) ->
    case decode_json(Raw) of
        {ok, Args} when is_map(Args) -> {ok, Args};
        {ok, _} ->
            {error, <<"the arguments are valid JSON but not a JSON object (",
                      (argument_summary(Raw))/binary, ")">>};
        error ->
            {error, <<"the arguments are not valid JSON (",
                      (argument_summary(Raw))/binary, ")">>}
    end;
decode_arguments(Other) ->
    {error, <<"the arguments are not a JSON object (",
              (argument_summary(describe(Other)))/binary, ")">>}.

argument_summary(Raw) ->
    <<(integer_to_binary(byte_size(Raw)))/binary, " bytes: \"",
      (preview(Raw))/binary, "\"">>.

invoke(Tool = #{ name := Name, executor := Executor }, Args, Opts) ->
    try Executor(Args, tool_device(Tool, Opts), Opts) of
        {ok, Text} -> Text;
        {rejected, Why} -> rejected_text(Name, Why);
        {error, Why} -> failed_text(Name, Why)
    catch
        Class:Reason ->
            ?event(agent, {tool_exception, Name, Class, Reason}),
            failed_text(Name, ?TOOL_EXCEPTION)
    end.

rejected_text(Name, Why) ->
    <<"Tool error: `", Name/binary, "` was not executed: ", Why/binary,
      ". No state was changed.">>.

failed_text(Name, Why) ->
    <<"Tool error: `", Name/binary, "` failed: ", Why/binary, ".">>.

%%% Executors. Each receives the filtered arguments, the device to resolve
%%% and the node options, and returns `{ok, Text}', `{rejected, Why}' (the
%%% tool did nothing) or `{error, Why}'.

%% @doc `http_request' through the relay device.
http_request(Args, Device, Opts) ->
    maybe
        {ok, Url} ?= required_text(<<"url">>, Args),
        {ok, Method} ?= http_method(maps:get(<<"method">>, Args, null)),
        {ok, Body} ?= http_body(Args),
        ok ?= check_url(Url, Opts),
        Payload =
            case Body of
                none -> #{ <<"path">> => Url, <<"method">> => Method };
                {Bytes, ContentType} ->
                    #{
                        <<"path">> => Url,
                        <<"method">> => Method,
                        <<"body">> => Bytes,
                        <<"content-type">> => ContentType
                    }
            end,
        http_result(
            hb_ao:resolve(
                #{ <<"device">> => Device },
                #{
                    <<"path">> => <<"call">>,
                    <<"target">> => <<"payload">>,
                    <<"payload">> => Payload
                },
                no_cache(Opts)
            ),
            Opts
        )
    end.

http_method(null) -> {ok, <<"GET">>};
http_method(Method) when is_binary(Method) ->
    Upper =
        case valid_utf8(Method) of
            true -> string:uppercase(Method);
            false -> Method
        end,
    case lists:member(Upper, ?HTTP_METHODS) of
        true -> {ok, Upper};
        false -> {rejected, <<"method must be GET, POST, PUT or DELETE">>}
    end;
http_method(_) ->
    {rejected, <<"method must be GET, POST, PUT or DELETE">>}.

http_body(Args) ->
    case maps:get(<<"body">>, Args, null) of
        null -> {ok, none};
        Body when is_binary(Body) ->
            {ok, {Body, content_type(Args, <<"text/plain">>)}};
        Json when is_map(Json); is_list(Json) ->
            {ok, {hb_json:encode(Json), content_type(Args, <<"application/json">>)}};
        _ -> {rejected, <<"body must be a string">>}
    end.

content_type(Args, Default) ->
    case maps:get(<<"content_type">>, Args, null) of
        Type when is_binary(Type), Type =/= <<>> -> Type;
        _ -> Default
    end.

%% @doc Only absolute http/https URLs. Unless the node option
%% `agent-http-allow-private' is true, `localhost' names and literal
%% addresses outside public unicast space are refused before any network
%% activity.
check_url(Url, Opts) ->
    case uri_string:parse(Url) of
        #{ scheme := Scheme, host := Host } when Host =/= <<>>, Host =/= "" ->
            case string:lowercase(hb_util:bin(Scheme)) of
                Allowed when Allowed =:= <<"http">>; Allowed =:= <<"https">> ->
                    AllowPrivate =
                        truthy(
                            hb_opts:get(<<"agent-http-allow-private">>, false, Opts)),
                    case AllowPrivate orelse public_host(hb_util:bin(Host)) of
                        true -> ok;
                        false ->
                            {rejected,
                                <<"the URL host is a local, private or "
                                  "special-use address">>}
                    end;
                _ -> {rejected, <<"only http and https URLs are allowed">>}
            end;
        _ -> {rejected, <<"the URL must be an absolute http or https URL">>}
    end.

public_host(Host) ->
    Name = hb_hostname:normalize(Host),
    case inet:parse_address(binary_to_list(Name)) of
        {ok, Address} -> hb_hostname:is_public_ip(Address);
        {error, _} ->
            not (Name =:= <<"localhost">> orelse
                 binary:longest_common_suffix([Name, <<".localhost">>]) =:= 10)
    end.

http_result({_Status, Response}, Opts) when is_map(Response) ->
    Status = hb_maps:get(<<"status">>, Response, <<"unknown">>, Opts),
    TypeLine =
        case hb_maps:get(<<"content-type">>, Response, not_found, Opts) of
            Type when is_binary(Type) -> <<"content-type: ", Type/binary, "\n">>;
            _ -> <<>>
        end,
    Body =
        case hb_maps:get(<<"body">>, Response, <<>>, Opts) of
            Bytes when is_binary(Bytes) -> Bytes;
            Other -> render(Other, Opts)
        end,
    {ok, <<"status: ", (hb_util:bin(Status))/binary, "\n", TypeLine/binary,
           "\n", Body/binary>>};
http_result(Other, Opts) ->
    device_error(Other, Opts).

%% @doc `lookup_data' through the cache device's `read' key.
lookup_data(Args, Device, Opts) ->
    maybe
        {ok, ID} ?= required_id(<<"id">>, Args),
        case hb_ao:resolve(
                #{ <<"device">> => Device },
                #{ <<"path">> => <<"read">>, <<"read">> => ID },
                no_cache(Opts)) of
            {ok, Result} -> {ok, render(Result, Opts)};
            {error, not_found} -> {ok, <<"Not found: ", ID/binary>>};
            Other -> device_error(Other, Opts)
        end
    end.

%% @doc `search_messages' through the query device's `only' key.
search_messages(Args, Device, Opts) ->
    maybe
        {ok, Match} ?= match_spec(maps:get(<<"match">>, Args, not_found)),
        {ok, Return} ?= search_return(maps:get(<<"return">>, Args, <<"paths">>)),
        case hb_ao:resolve(
                #{ <<"device">> => Device },
                #{
                    <<"path">> => <<"only">>,
                    <<"only">> => Match,
                    <<"return">> => Return
                },
                no_cache(Opts)) of
            {ok, Result} -> {ok, render(Result, Opts)};
            {error, not_found} -> {ok, <<"No matching messages.">>};
            Other -> device_error(Other, Opts)
        end
    end.

match_spec(Match) when is_map(Match), map_size(Match) > 0 ->
    Scalar =
        lists:all(
            fun({Key, Value}) ->
                is_binary(Key) andalso
                    (is_binary(Value) orelse is_number(Value) orelse
                        is_boolean(Value))
            end,
            maps:to_list(Match)
        ),
    case Scalar of
        true -> {ok, Match};
        false -> match_spec(invalid)
    end;
match_spec(_) ->
    {rejected,
        <<"match must be a non-empty object whose values are strings, numbers "
          "or booleans">>}.

search_return(Return) ->
    case lists:member(Return, ?SEARCH_RETURNS) of
        true -> {ok, Return};
        false -> {rejected, <<"return must be paths, messages or count">>}
    end.

%% @doc `get_arweave_tx' through the Arweave device's `tx' key, header only.
get_arweave_tx(Args, Device, Opts) ->
    maybe
        {ok, ID} ?= required_id(<<"id">>, Args),
        case hb_ao:resolve(
                #{ <<"device">> => Device },
                #{
                    <<"path">> => <<"tx">>,
                    <<"tx">> => ID,
                    <<"method">> => <<"GET">>,
                    <<"exclude-data">> => true
                },
                no_cache(Opts)) of
            {ok, Result} -> {ok, render(Result, Opts)};
            {error, not_found} -> {ok, <<"Transaction not found: ", ID/binary>>};
            Other -> device_error(Other, Opts)
        end
    end.

%% @doc `bundle_item': sign the data as an ANS-104 item with the node's
%% wallet and submit it to the bundler device's `item' key.
bundle_item(Args, Device, Opts) ->
    maybe
        {ok, Data} ?= required_text(<<"data">>, Args),
        Item =
            hb_message:commit(
                #{
                    <<"data">> => Data,
                    <<"content-type">> => content_type(Args, <<"text/plain">>)
                },
                Opts,
                <<"ans104@1.0">>
            ),
        case hb_ao:resolve(
                #{ <<"device">> => Device },
                #{
                    <<"path">> => <<"item">>,
                    <<"bundler-subject">> => <<"item">>,
                    <<"item">> => Item
                },
                no_cache(Opts)) of
            {ok, Result} -> {ok, bundle_text(Result, Opts)};
            Other -> device_error(Other, Opts)
        end
    end.

%% @doc A failed device call as a tool failure. Status and text of an error
%% message, and atom or text reasons, are shown; other terms are not.
device_error({error, Reason}, Opts) when is_map(Reason) ->
    Status =
        case status_code(hb_maps:get(<<"status">>, Reason, not_found, Opts)) of
            Code when is_integer(Code) ->
                <<"status ", (integer_to_binary(Code))/binary>>;
            _ -> <<>>
        end,
    Body =
        case hb_maps:get(<<"body">>, Reason, not_found, Opts) of
            Text when is_binary(Text), Text =/= <<>> -> Text;
            _ -> <<>>
        end,
    case {Status, Body} of
        {<<>>, <<>>} ->
            ?event(agent, {tool_device_error, Reason}),
            {error, ?DEVICE_FAILED};
        {<<>>, _} -> {error, Body};
        {_, <<>>} -> {error, Status};
        _ -> {error, <<Status/binary, ": ", Body/binary>>}
    end;
device_error({error, Reason}, _Opts) ->
    ?event(agent, {tool_device_error, Reason}),
    {error, reason_text(Reason, ?DEVICE_FAILED)};
device_error(Other, _Opts) ->
    ?event(agent, {tool_device_result, Other}),
    {error, ?DEVICE_FAILED}.

bundle_text(Result, Opts) when is_map(Result) ->
    case hb_maps:get(<<"id">>, Result, not_found, Opts) of
        ID when is_binary(ID) ->
            <<"Submitted data item ", ID/binary, " to the node's bundler.">>;
        _ -> render(Result, Opts)
    end;
bundle_text(Result, Opts) ->
    render(Result, Opts).

required_text(Key, Args) ->
    case maps:get(Key, Args, null) of
        Text when is_binary(Text), Text =/= <<>> -> {ok, Text};
        null -> {rejected, <<"missing required argument `", Key/binary, "`">>};
        _ -> {rejected, <<"`", Key/binary, "` must be a non-empty string">>}
    end.

required_id(Key, Args) ->
    case required_text(Key, Args) of
        {ok, ID} ->
            case is_txid(ID) of
                true -> {ok, ID};
                false ->
                    {rejected,
                        <<"`", Key/binary, "` must be a 43-character base64url ID">>}
            end;
        Rejected -> Rejected
    end.

is_txid(ID) when byte_size(ID) =:= 43 ->
    lists:all(
        fun(C) ->
            (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
                (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_
        end,
        binary_to_list(ID)
    );
is_txid(_) -> false.

%%%===================================================================
%%% Text and value helpers
%%%===================================================================

%% @doc Options for calls to other devices: their results are not cached and
%% carry no hashpath.
no_cache(Opts) ->
    Opts#{
        <<"hashpath">> => ignore,
        <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
    }.

%% @doc `true', `1', or the text `true' or `1' (any case, surrounding
%% whitespace ignored). Every other value, including text that is not valid
%% UTF-8, is false.
truthy(true) -> true;
truthy(1) -> true;
truthy(Bin) when is_binary(Bin) ->
    case trimmed(Bin) of
        {ok, Text} -> lists:member(string:lowercase(Text), [<<"true">>, <<"1">>]);
        error -> false
    end;
truthy(_) -> false.

%% @doc Text without surrounding whitespace, or `error' for values that are
%% not valid UTF-8 text.
trimmed(Bin) when is_binary(Bin) ->
    case valid_utf8(Bin) of
        true -> {ok, unicode:characters_to_binary(string:trim(Bin))};
        false -> error
    end;
trimmed(_) ->
    error.

valid_utf8(Bin) ->
    unicode:characters_to_binary(Bin) =:= Bin.

%% @doc A positive integer from an integer, an integral float, or decimal
%% text.
positive_int(N) when is_integer(N), N > 0 -> {ok, N};
positive_int(F) when is_float(F), F >= 1.0, F == trunc(F) -> {ok, trunc(F)};
positive_int(Bin) when is_binary(Bin) ->
    case trimmed(Bin) of
        {ok, Text} ->
            try binary_to_integer(Text) of
                N when N > 0 -> {ok, N};
                _ -> error
            catch _:_ -> error
            end;
        error -> error
    end;
positive_int(_) -> error.

%% @doc Text from a binary or a number, as valid UTF-8. Empty text counts
%% as absent.
nonempty_text(Bin) when is_binary(Bin), Bin =/= <<>> -> {ok, utf8_sanitize(Bin)};
nonempty_text(N) when is_integer(N) -> {ok, integer_to_binary(N)};
nonempty_text(F) when is_float(F) -> {ok, float_to_binary(F, [short])};
nonempty_text(_) -> error.

decode_json(Bin) ->
    try {ok, hb_json:decode(Bin)} catch _:_ -> error end.

json_encodable(Term) ->
    try hb_json:encode(Term), true catch _:_ -> false end.

%% @doc Render a tool result as text: binaries as they are, other values as
%% JSON without commitments or private keys.
render(Bin, _Opts) when is_binary(Bin) -> Bin;
render(Term, Opts) ->
    Clean =
        try clean(hb_private:reset(hb_cache:ensure_all_loaded(Term, Opts)))
        catch _:_ -> Term
        end,
    try hb_json:encode(Clean)
    catch _:_ -> iolist_to_binary(io_lib:format("~0tP", [Clean, 64]))
    end.

clean(Map) when is_map(Map) ->
    maps:map(fun(_Key, Value) -> clean(Value) end,
        maps:without([<<"commitments">>], Map));
clean(List) when is_list(List) -> [clean(Value) || Value <- List];
clean(Value) -> Value.

%% @doc The text of an atom or binary error reason; `Generic' for any other
%% term, so that internal state is never shown.
reason_text(Reason, _Generic) when is_atom(Reason) ->
    bound_text(atom_to_binary(Reason), ?MAX_DETAIL_BYTES);
reason_text(Reason, _Generic) when is_binary(Reason), Reason =/= <<>> ->
    bound_text(Reason, ?MAX_DETAIL_BYTES);
reason_text(_Reason, Generic) ->
    Generic.

%% @doc A short, printable description of a term.
describe(Bin) when is_binary(Bin) -> bound_text(Bin, ?MAX_DETAIL_BYTES);
describe(Term) ->
    bound_text(
        iolist_to_binary(io_lib:format("~0tP", [Term, 12])),
        ?MAX_DETAIL_BYTES
    ).

preview(Bin) -> bound_text(Bin, ?PREVIEW_BYTES).

%% @doc At most `Max' bytes of valid UTF-8 taken from the start of `Bin',
%% cut on a character boundary; invalid sequences become U+FFFD. A shortened
%% text ends with a marker giving the shown and original sizes.
bound_text(Bin, Max) ->
    Clean = utf8_sanitize(utf8_prefix(Bin, Max)),
    Kept = utf8_prefix(Clean, Max),
    case byte_size(Bin) > Max orelse byte_size(Clean) > Max of
        false -> Kept;
        true ->
            <<Kept/binary, "\n[truncated: ",
              (integer_to_binary(byte_size(Kept)))/binary, " of ",
              (integer_to_binary(byte_size(Bin)))/binary, " bytes shown]">>
    end.

%% @doc The longest prefix of at most `Max' bytes that does not split a
%% UTF-8 sequence.
utf8_prefix(Bin, Max) when byte_size(Bin) =< Max -> Bin;
utf8_prefix(Bin, Max) -> utf8_prefix(Bin, Max, 3).

utf8_prefix(Bin, Cut, Steps) when Cut > 0, Steps > 0 ->
    case binary:at(Bin, Cut) band 16#C0 of
        16#80 -> utf8_prefix(Bin, Cut - 1, Steps - 1);
        _ -> binary:part(Bin, 0, Cut)
    end;
utf8_prefix(Bin, Cut, _Steps) ->
    binary:part(Bin, 0, Cut).

%% @doc Replace every invalid UTF-8 sequence with U+FFFD.
utf8_sanitize(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Bin -> Bin;
        _ -> utf8_sanitize(Bin, <<>>)
    end.

utf8_sanitize(<<Char/utf8, Rest/binary>>, Acc) ->
    utf8_sanitize(Rest, <<Acc/binary, Char/utf8>>);
utf8_sanitize(<<_, Rest/binary>>, Acc) ->
    utf8_sanitize(Rest, <<Acc/binary, 16#FFFD/utf8>>);
utf8_sanitize(<<>>, Acc) ->
    Acc.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

%%% Stub devices. Tests configure the inference device and the tool devices
%%% through node options, exactly as an operator would, using device messages
%%% whose keys are functions. Every call is recorded in an ETS table.

%% @doc Test fixture: a recording table and node options that route the model
%% and every tool to stub devices. `Replies' is a list of model replies (the
%% last one repeats) or a function of the call number and the decoded request.
setup(Replies) -> setup(Replies, #{}).
setup(Replies, ExtraOpts) ->
    Table = ets:new(agent_test, [ordered_set, public]),
    Opts =
        maps:merge(
            #{
                <<"agent-inference-device">> => model_stub(Table, Replies),
                <<"agent-tool-devices">> => tool_stubs(Table)
            },
            ExtraOpts
        ),
    {Table, Opts}.

model_stub(Table, Replies) ->
    Counter = counters:new(1, []),
    #{
        <<"completions">> =>
            fun(Base, Req, Opts) ->
                counters:add(Counter, 1, 1),
                N = counters:get(Counter, 1),
                Body = hb_json:decode(maps:get(<<"body">>, Req)),
                ets:insert(Table, {{model, N}, Body, Base, Req, Opts}),
                stub_reply(pick_reply(N, Body, Replies))
            end
    }.

pick_reply(N, Body, Replies) when is_function(Replies) -> Replies(N, Body);
pick_reply(N, _Body, Replies) -> lists:nth(min(N, length(Replies)), Replies).

stub_reply({ok, Response}) when is_map(Response) ->
    {ok, #{
        <<"status">> => 200,
        <<"content-type">> => <<"application/json">>,
        <<"body">> => hb_json:encode(Response)
    }};
stub_reply({result, Result}) ->
    {ok, Result};
stub_reply({raw, Body}) ->
    {ok, #{ <<"status">> => 200, <<"body">> => Body }};
stub_reply(Other) ->
    Other.

tool_stubs(Table) ->
    #{
        <<"http_request">> =>
            recorder(Table, http, <<"call">>,
                fun(_) ->
                    {ok, #{
                        <<"status">> => 200,
                        <<"content-type">> => <<"text/plain">>,
                        <<"body">> => <<"pong">>
                    }}
                end),
        <<"lookup_data">> =>
            recorder(Table, lookup, <<"read">>,
                fun(_) -> {ok, #{ <<"data">> => <<"cached">> }} end),
        <<"search_messages">> =>
            recorder(Table, search, <<"only">>,
                fun(_) -> {ok, [<<"path-a">>, <<"path-b">>]} end),
        <<"get_arweave_tx">> =>
            recorder(Table, arweave, <<"tx">>,
                fun(_) -> {ok, #{ <<"owner">> => <<"someone">> }} end),
        <<"bundle_item">> =>
            recorder(Table, bundle, <<"item">>,
                fun(_) ->
                    {ok, #{ <<"id">> => binary:copy(<<"b">>, 43),
                            <<"timestamp">> => 1 }}
                end)
    }.

recorder(Table, Kind, Key, Handler) ->
    #{
        Key =>
            fun(_Base, Req, _Opts) ->
                ets:insert(
                    Table,
                    {{tool, erlang:unique_integer([monotonic, positive])},
                        Kind, Req}
                ),
                Handler(Req)
            end
    }.

model_requests(Table) ->
    [Body || {{model, _}, Body, _, _, _} <- ets:tab2list(Table)].

tool_requests(Table, Kind) ->
    [Req || {{tool, _}, K, Req} <- ets:tab2list(Table), K =:= Kind].

%% @doc Resolve `run' with the given request keys.
run_agent(ReqKeys, Opts) ->
    run_agent(#{ <<"device">> => <<"agent@1.0">> }, ReqKeys, Opts).
run_agent(Base, ReqKeys, Opts) ->
    {ok, Result} =
        run(
            Base,
            maps:merge(
                #{
                    <<"path">> => <<"run">>,
                    <<"agent-user-prompt">> => <<"Test task">>
                },
                ReqKeys
            ),
            Opts
        ),
    Result.

%%% Model reply builders (OpenAI chat-completion shape).

reply_with(Message, FinishReason) ->
    {ok, #{
        <<"id">> => <<"chatcmpl-test">>,
        <<"object">> => <<"chat.completion">>,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => maps:merge(#{ <<"role">> => <<"assistant">> }, Message),
            <<"finish_reason">> => FinishReason
        }]
    }}.

answer_reply(Content) ->
    reply_with(#{ <<"content">> => Content }, <<"stop">>).

tool_reply(Calls) ->
    reply_with(#{ <<"content">> => null, <<"tool_calls">> => Calls }, <<"tool_calls">>).

tool_call(Id, Name, Args) when is_binary(Args) ->
    #{
        <<"id">> => Id,
        <<"type">> => <<"function">>,
        <<"function">> => #{ <<"name">> => Name, <<"arguments">> => Args }
    };
tool_call(Id, Name, Args) ->
    tool_call(Id, Name, hb_json:encode(Args)).

http_call(Id) ->
    tool_call(Id, <<"http_request">>, #{ <<"url">> => <<"https://example.com/">> }).

tool_contents(Messages) ->
    [Content || #{ <<"role">> := <<"tool">>, <<"content">> := Content } <- Messages].

contains(Bin, Part) -> binary:match(Bin, Part) =/= nomatch.

%%% Answers and the result message.

single_turn_answer_test() ->
    {Table, Opts} = setup([answer_reply(<<"Hello! How can I help?">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"Hello! How can I help?">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(1, maps:get(<<"agent-iterations">>, Result)),
    ?assertNot(maps:is_key(<<"agent-error">>, Result)),
    [Request] = model_requests(Table),
    ?assertEqual(
        [<<"system">>, <<"user">>],
        [Role || #{ <<"role">> := Role } <- maps:get(<<"messages">>, Request)]
    ),
    ?assertEqual(<<"auto">>, maps:get(<<"tool_choice">>, Request)),
    ?assertEqual(
        [<<"http_request">>, <<"lookup_data">>, <<"search_messages">>,
         <<"get_arweave_tx">>],
        [Name || #{ <<"function">> := #{ <<"name">> := Name } }
            <- maps:get(<<"tools">>, Request)]
    ).

result_echoes_base_test() ->
    {_Table, Opts} = setup([answer_reply(<<"done">>)]),
    Base = #{
        <<"device">> => <<"agent@1.0">>,
        <<"agent-user-prompt">> => <<"echoed">>,
        <<"agent-error">> => <<"stale">>,
        <<"agent-error-detail">> => #{ <<"stale">> => true },
        <<"commitments">> => #{ <<"stale">> => #{} }
    },
    Result = run_agent(Base, #{}, Opts),
    ?assertEqual(<<"echoed">>, maps:get(<<"agent-user-prompt">>, Result)),
    ?assertEqual(<<"agent@1.0">>, maps:get(<<"device">>, Result)),
    ?assertEqual(<<"done">>, maps:get(<<"agent-answer">>, Result)),
    ?assertNot(maps:is_key(<<"agent-error">>, Result)),
    ?assertNot(maps:is_key(<<"agent-error-detail">>, Result)),
    ?assertNot(maps:is_key(<<"commitments">>, Result)).

refusal_is_the_answer_when_content_is_empty_test() ->
    {_Table, Opts} =
        setup([reply_with(#{ <<"content">> => null,
                             <<"refusal">> => <<"I cannot help with that.">> },
                          <<"stop">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"I cannot help with that.">>, maps:get(<<"agent-answer">>, Result)).

array_content_test() ->
    {_Table, Opts} =
        setup([reply_with(
            #{ <<"content">> => [
                #{ <<"type">> => <<"text">>, <<"text">> => <<"Hello, ">> },
                #{ <<"type">> => <<"image_url">>, <<"image_url">> => #{} },
                #{ <<"type">> => <<"text">>, <<"text">> => <<"world.">> }
            ] },
            <<"stop">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"Hello, world.">>, maps:get(<<"agent-answer">>, Result)).

%%% Tool rounds.

tool_round_trip_test() ->
    {Table, Opts} =
        setup([
            tool_reply([http_call(<<"call_1">>)]),
            answer_reply(<<"It said pong.">>)
        ]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"It said pong.">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(2, maps:get(<<"agent-iterations">>, Result)),
    [HttpReq] = tool_requests(Table, http),
    ?assertEqual(
        #{ <<"path">> => <<"https://example.com/">>, <<"method">> => <<"GET">> },
        maps:get(<<"payload">>, HttpReq)
    ),
    [_, Second] = model_requests(Table),
    Messages = maps:get(<<"messages">>, Second),
    ?assertEqual(
        [<<"system">>, <<"user">>, <<"assistant">>, <<"tool">>],
        [Role || #{ <<"role">> := Role } <- Messages]
    ),
    [_, _, Assistant, Tool] = Messages,
    ?assertEqual(null, maps:get(<<"content">>, Assistant)),
    [#{ <<"id">> := <<"call_1">> }] = maps:get(<<"tool_calls">>, Assistant),
    ?assertEqual(<<"call_1">>, maps:get(<<"tool_call_id">>, Tool)),
    ?assertEqual(
        <<"status: 200\ncontent-type: text/plain\n\npong">>,
        maps:get(<<"content">>, Tool)
    ).

multiple_tool_calls_test() ->
    Calls = [
        tool_call(<<"a">>, <<"http_request">>,
            #{ <<"url">> => <<"https://example.com/a">> }),
        tool_call(<<"b">>, <<"http_request">>,
            #{ <<"url">> => <<"https://example.com/b">> })
    ],
    {Table, Opts} = setup([tool_reply(Calls), answer_reply(<<"Both fetched.">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"Both fetched.">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(
        [<<"https://example.com/a">>, <<"https://example.com/b">>],
        [Path || #{ <<"payload">> := #{ <<"path">> := Path } }
            <- tool_requests(Table, http)]
    ),
    [_, Second] = model_requests(Table),
    ?assertEqual(
        [<<"a">>, <<"b">>],
        [Id || #{ <<"role">> := <<"tool">>, <<"tool_call_id">> := Id }
            <- maps:get(<<"messages">>, Second)]
    ).

tool_calls_per_completion_are_bounded_test() ->
    Calls = [http_call(integer_to_binary(N)) || N <- lists:seq(1, 20)],
    {Table, Opts} = setup([tool_reply(Calls), answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    ?assertEqual(16, length(tool_requests(Table, http))),
    [_, Second] = model_requests(Table),
    Contents = tool_contents(maps:get(<<"messages">>, Second)),
    ?assertEqual(20, length(Contents)),
    ?assert(contains(lists:last(Contents), <<"at most 16 tool calls">>)),
    {Limited, LimitedOpts} =
        setup([tool_reply(Calls), answer_reply(<<"ok">>)],
              #{ <<"agent-max-tool-calls-per-completion">> => <<"3">> }),
    _ = run_agent(#{}, LimitedOpts),
    ?assertEqual(3, length(tool_requests(Limited, http))).

tool_calls_per_run_are_bounded_test() ->
    TwoCalls = tool_reply([http_call(<<"a">>), http_call(<<"b">>)]),
    {Table, Opts} =
        setup([TwoCalls, TwoCalls, TwoCalls, answer_reply(<<"done">>)],
              #{ <<"agent-max-tool-calls-per-run">> => 3 }),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"done">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(3, length(tool_requests(Table, http))),
    [_, _, Third, Fourth] = model_requests(Table),
    [_, _, _, Skipped] = tool_contents(maps:get(<<"messages">>, Third)),
    ?assert(contains(Skipped, <<"a run may make at most 3 tool calls">>)),
    [_, _, _, _, _, Last] = tool_contents(maps:get(<<"messages">>, Fourth)),
    ?assert(contains(Last, <<"was not executed">>)).

tool_failure_is_reported_to_the_model_test() ->
    Failing = #{ <<"call">> => fun(_, _, _) -> throw(upstream_unavailable) end },
    {Table, Opts0} =
        setup([tool_reply([http_call(<<"c">>)]), answer_reply(<<"It failed.">>)]),
    Opts = Opts0#{ <<"agent-tool-devices">> => #{ <<"http_request">> => Failing } },
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"It failed.">>, maps:get(<<"agent-answer">>, Result)),
    [_, Second] = model_requests(Table),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assertEqual(
        <<"Tool error: `http_request` failed: the tool raised an exception.">>,
        Content
    ).

tool_device_errors_hide_internal_terms_test() ->
    Reply = fun(Error) -> #{ <<"read">> => fun(_, _, _) -> Error end } end,
    ID = binary:copy(<<"a">>, 43),
    Content = fun(Error) ->
        {Table, Opts0} =
            setup([tool_reply([tool_call(<<"l">>, <<"lookup_data">>,
                                         #{ <<"id">> => ID })]),
                   answer_reply(<<"ok">>)]),
        Opts = Opts0#{ <<"agent-tool-devices">> =>
                           #{ <<"lookup_data">> => Reply(Error) } },
        _ = run_agent(#{}, Opts),
        [_, Second] = model_requests(Table),
        [Text] = tool_contents(maps:get(<<"messages">>, Second)),
        Text
    end,
    ?assert(contains(Content({error, timeout}), <<"failed: timeout.">>)),
    ?assert(contains(
        Content({error, #{ <<"status">> => 502, <<"body">> => <<"bad gateway">> }}),
        <<"failed: status 502: bad gateway.">>
    )),
    Hidden = Content({error, {internal, #{ <<"priv-wallet">> => <<"secret">> }}}),
    ?assert(contains(Hidden, <<"failed: the device returned an error.">>)),
    ?assertNot(contains(Hidden, <<"secret">>)).

http_error_status_is_an_observation_test() ->
    NotFound =
        #{ <<"call">> =>
            fun(_, _, _) ->
                {error, #{ <<"status">> => 404, <<"body">> => <<"missing">> }}
            end },
    {Table, Opts0} =
        setup([tool_reply([http_call(<<"c">>)]), answer_reply(<<"Not there.">>)]),
    Opts = Opts0#{ <<"agent-tool-devices">> => #{ <<"http_request">> => NotFound } },
    _ = run_agent(#{}, Opts),
    [_, Second] = model_requests(Table),
    ?assertEqual(
        [<<"status: 404\n\nmissing">>],
        tool_contents(maps:get(<<"messages">>, Second))
    ).

%%% Iteration limit.

always_calls_tool(_N, _Body) ->
    tool_reply([http_call(<<"loop">>)]).

max_iterations_from_http_text_test() ->
    {Table, Opts} = setup(fun always_calls_tool/2),
    Result = run_agent(#{ <<"agent-max-iterations">> => <<"2">> }, Opts),
    ?assertEqual(<<"max_iterations_exceeded">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(2, maps:get(<<"agent-iterations">>, Result)),
    ?assertEqual(#{ <<"limit">> => 2 }, maps:get(<<"agent-error-detail">>, Result)),
    ?assertEqual(
        <<"Max iterations reached. Could not complete the task.">>,
        maps:get(<<"agent-answer">>, Result)
    ),
    ?assertEqual(2, length(model_requests(Table))),
    ?assertEqual(2, length(tool_requests(Table, http))).

max_iterations_integer_test() ->
    {Table, Opts} = setup(fun always_calls_tool/2),
    Result = run_agent(#{ <<"agent-max-iterations">> => 3 }, Opts),
    ?assertEqual(<<"max_iterations_exceeded">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(3, maps:get(<<"agent-iterations">>, Result)),
    ?assertEqual(3, length(model_requests(Table))).

max_iterations_normalization_test() ->
    Opts = #{},
    Max = fun(Value) ->
        max_iterations(#{ <<"agent-max-iterations">> => Value }, Opts)
    end,
    ?assertEqual(10, max_iterations(#{}, Opts)),
    ?assertEqual(4, Max(<<" 4 ">>)),
    ?assertEqual(5, Max(5.0)),
    lists:foreach(
        fun(Invalid) -> ?assertEqual(10, Max(Invalid)) end,
        [<<"0">>, <<"-3">>, <<"abc">>, <<>>, 0, -1, 2.5, #{}, [1]]
    ).

max_iterations_operator_limit_test() ->
    Limited = fun(Limit, Value) ->
        max_iterations(
            #{ <<"agent-max-iterations">> => Value },
            #{ <<"agent-max-iterations-limit">> => Limit }
        )
    end,
    ?assertEqual(25, max_iterations(#{ <<"agent-max-iterations">> => 1000 }, #{})),
    ?assertEqual(3, Limited(3, <<"50">>)),
    ?assertEqual(4, Limited(<<"4">>, 10)),
    ?assertEqual(3, max_iterations(#{}, #{ <<"agent-max-iterations-limit">> => 3 })),
    ?assertEqual(25, Limited(<<"invalid">>, 100)),
    {Table, Opts} =
        setup(fun always_calls_tool/2, #{ <<"agent-max-iterations-limit">> => 3 }),
    Result = run_agent(#{ <<"agent-max-iterations">> => <<"50">> }, Opts),
    ?assertEqual(3, maps:get(<<"agent-iterations">>, Result)),
    ?assertEqual(3, length(model_requests(Table))).

%%% Tool arguments.

invalid_json_arguments_are_not_executed_test() ->
    Call = tool_call(<<"bad">>, <<"http_request">>, <<"{\"url\": \"https://exa">>),
    {Table, Opts} = setup([tool_reply([Call]), answer_reply(<<"Retrying failed.">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"Retrying failed.">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual([], tool_requests(Table, http)),
    [_, Second] = model_requests(Table),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Content, <<"was not executed">>)),
    ?assert(contains(Content, <<"not valid JSON">>)),
    ?assert(contains(Content, <<"No state was changed.">>)),
    ?assert(contains(Content, <<"20 bytes">>)).

non_object_arguments_are_not_executed_test() ->
    lists:foreach(
        fun(Args) ->
            Call = tool_call(<<"c">>, <<"http_request">>, Args),
            {Table, Opts} = setup([tool_reply([Call]), answer_reply(<<"ok">>)]),
            Result = run_agent(#{}, Opts),
            ?assertEqual(<<"ok">>, maps:get(<<"agent-answer">>, Result)),
            ?assertEqual([], tool_requests(Table, http)),
            [_, Second] = model_requests(Table),
            [Content] = tool_contents(maps:get(<<"messages">>, Second)),
            ?assert(contains(Content, <<"not a JSON object">>))
        end,
        [<<"[]">>, <<"null">>, <<"\"https://example.com\"">>, <<"42">>]
    ).

argument_preview_is_bounded_utf8_test() ->
    Long = <<"{", (binary:copy(<<16#20AC/utf8>>, 200))/binary>>,
    Call = tool_call(<<"c">>, <<"http_request">>, Long),
    {Table, Opts} = setup([tool_reply([Call]), answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    [_, Second] = model_requests(Table),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assertEqual(Content, unicode:characters_to_binary(Content)),
    ?assert(byte_size(Content) < 400).

arguments_are_filtered_to_declared_keys_test() ->
    ID = binary:copy(<<"a">>, 43),
    Calls = [
        tool_call(<<"l">>, <<"lookup_data">>,
            #{ <<"id">> => ID, <<"store">> => <<"elsewhere">> }),
        tool_call(<<"h">>, <<"http_request">>,
            #{ <<"url">> => <<"https://example.com/">>,
               <<"peer">> => <<"http://10.0.0.1">>,
               <<"commit-request">> => true })
    ],
    {Table, Opts} = setup([tool_reply(Calls), answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    [LookupReq] = tool_requests(Table, lookup),
    ?assertEqual(ID, maps:get(<<"read">>, LookupReq)),
    ?assertNot(maps:is_key(<<"store">>, LookupReq)),
    [HttpReq] = tool_requests(Table, http),
    ?assertEqual(
        #{ <<"path">> => <<"https://example.com/">>, <<"method">> => <<"GET">> },
        maps:get(<<"payload">>, HttpReq)
    ),
    ?assertNot(maps:is_key(<<"peer">>, HttpReq)).

unknown_tool_is_not_executed_test() ->
    Call = tool_call(<<"u">>, <<"run_shell">>, #{ <<"cmd">> => <<"ls">> }),
    {Table, Opts} = setup([tool_reply([Call]), answer_reply(<<"No such tool.">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"No such tool.">>, maps:get(<<"agent-answer">>, Result)),
    [_, Second] = model_requests(Table),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Content, <<"`run_shell` was not executed">>)),
    ?assert(contains(Content, <<"http_request, lookup_data">>)).

%%% finish_reason dispatch.

truncated_tool_call_is_not_executed_test() ->
    Truncated =
        reply_with(
            #{ <<"content">> => null,
               <<"tool_calls">> => [tool_call(<<"t">>, <<"http_request">>,
                                              <<"{\"url\": \"https://ex">>)] },
            <<"length">>),
    {Table, Opts} = setup([Truncated]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"incomplete_response">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        #{ <<"finish-reason">> => <<"length">>,
           <<"cause">> => <<"truncated-tool-call">> },
        maps:get(<<"agent-error-detail">>, Result)
    ),
    ?assertEqual(1, maps:get(<<"agent-iterations">>, Result)),
    ?assertEqual([], tool_requests(Table, http)).

truncated_answer_is_continued_test() ->
    {Table, Opts} =
        setup([
            reply_with(#{ <<"content">> => <<"The answer is ">> }, <<"length">>),
            reply_with(#{ <<"content">> => <<"forty">> }, <<"length">>),
            answer_reply(<<"-two.">>)
        ]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"The answer is forty-two.">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(3, maps:get(<<"agent-iterations">>, Result)),
    [_, Second, _] = model_requests(Table),
    [_, _, Partial, Continue] = maps:get(<<"messages">>, Second),
    ?assertEqual(
        #{ <<"role">> => <<"assistant">>, <<"content">> => <<"The answer is ">> },
        Partial
    ),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, Continue)).

continuations_count_against_the_limit_test() ->
    {Table, Opts} =
        setup([reply_with(#{ <<"content">> => <<"more">> }, <<"length">>)]),
    Result = run_agent(#{ <<"agent-max-iterations">> => 2 }, Opts),
    ?assertEqual(<<"max_iterations_exceeded">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(2, length(model_requests(Table))).

truncated_empty_answer_is_incomplete_test() ->
    {_Table, Opts} =
        setup([reply_with(#{ <<"content">> => <<>>,
                             <<"reasoning_content">> => <<"thinking">> },
                          <<"length">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"incomplete_response">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        <<"empty-content">>,
        maps:get(<<"cause">>, maps:get(<<"agent-error-detail">>, Result))
    ).

partial_answer_resets_at_tool_boundary_test() ->
    {_Table, Opts} =
        setup([
            reply_with(#{ <<"content">> => <<"draft ">> }, <<"length">>),
            tool_reply([http_call(<<"c">>)]),
            answer_reply(<<"final">>)
        ]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"final">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(3, maps:get(<<"agent-iterations">>, Result)).

content_filter_ends_the_run_test() ->
    {_Table, Opts} =
        setup([reply_with(#{ <<"content">> => <<"partial">> }, <<"content_filter">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"content_filtered">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        #{ <<"finish-reason">> => <<"content_filter">> },
        maps:get(<<"agent-error-detail">>, Result)
    ),
    ?assertEqual(
        <<"The model response was blocked by a content filter.">>,
        maps:get(<<"agent-answer">>, Result)
    ).

error_finish_reason_ends_the_run_test() ->
    {_Table, Opts} = setup([reply_with(#{ <<"content">> => null }, <<"error">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"model_error">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        #{ <<"finish-reason">> => <<"error">> },
        maps:get(<<"agent-error-detail">>, Result)
    ).

unknown_finish_reason_ends_the_run_test() ->
    {_Table, Opts} = setup([reply_with(#{ <<"content">> => <<"x">> }, <<"abort">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"unsupported_finish_reason">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        #{ <<"finish-reason">> => <<"abort">> },
        maps:get(<<"agent-error-detail">>, Result)
    ).

missing_finish_reason_is_inferred_test() ->
    {Table, Opts} =
        setup([
            reply_with(#{ <<"content">> => null,
                          <<"tool_calls">> => [http_call(<<"c">>)] }, null),
            reply_with(#{ <<"content">> => <<"inferred">> }, null)
        ]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"inferred">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(1, length(tool_requests(Table, http))).

stop_with_tool_calls_executes_them_test() ->
    Named = #{ <<"type">> => <<"function">>,
               <<"function">> => #{ <<"name">> => <<"http_request">> } },
    Forced =
        reply_with(
            #{ <<"content">> => <<>>, <<"tool_calls">> => [http_call(<<"f">>)] },
            <<"stop">>),
    {Table, Opts} = setup([Forced, answer_reply(<<"Fetched.">>)]),
    Result = run_agent(#{ <<"agent-tool-choice">> => Named }, Opts),
    ?assertEqual(<<"Fetched.">>, maps:get(<<"agent-answer">>, Result)),
    ?assertNot(maps:is_key(<<"agent-error">>, Result)),
    ?assertEqual(2, maps:get(<<"agent-iterations">>, Result)),
    ?assertEqual(1, length(tool_requests(Table, http))),
    [First, Second] = model_requests(Table),
    ?assertEqual(Named, maps:get(<<"tool_choice">>, First)),
    ?assertEqual(<<"auto">>, maps:get(<<"tool_choice">>, Second)).

empty_stop_is_incomplete_test() ->
    {_Table, Opts} = setup([answer_reply(<<>>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"incomplete_response">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        #{ <<"finish-reason">> => <<"stop">>, <<"cause">> => <<"empty-content">> },
        maps:get(<<"agent-error-detail">>, Result)
    ),
    {_, ContinuedOpts} =
        setup([reply_with(#{ <<"content">> => <<"whole">> }, <<"length">>),
               answer_reply(<<>>)]),
    Continued = run_agent(#{}, ContinuedOpts),
    ?assertEqual(<<"whole">>, maps:get(<<"agent-answer">>, Continued)),
    ?assertNot(maps:is_key(<<"agent-error">>, Continued)).

tool_calls_finish_without_calls_test() ->
    {_Table, Opts} =
        setup([reply_with(#{ <<"content">> => <<"x">> }, <<"tool_calls">>)]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"incomplete_response">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        <<"missing-tool-calls">>,
        maps:get(<<"cause">>, maps:get(<<"agent-error-detail">>, Result))
    ).

%%% Model call failures.

model_call_error_test() ->
    Failure =
        {error, #{
            <<"status">> => 503,
            <<"body">> =>
                hb_json:encode(#{ <<"error">> => #{
                    <<"message">> => <<"overloaded">>,
                    <<"type">> => <<"server_error">> } })
        }},
    {_Table, Opts} = setup([Failure]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"model_error">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(1, maps:get(<<"agent-iterations">>, Result)),
    ?assertEqual(
        #{ <<"status">> => 503, <<"message">> => <<"overloaded">>,
           <<"type">> => <<"server_error">> },
        maps:get(<<"agent-error-detail">>, Result)
    ).

error_status_in_result_test() ->
    {_Table, Opts} =
        setup([{result, #{ <<"status">> => 400,
                       <<"body">> =>
                           <<"{\"object\":\"error\",\"message\":\"bad model\","
                             "\"code\":400}">> }}]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"model_error">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        #{ <<"status">> => 400, <<"message">> => <<"bad model">>, <<"code">> => 400 },
        maps:get(<<"agent-error-detail">>, Result)
    ).

error_envelope_in_success_body_test() ->
    {_Table, Opts} =
        setup([{ok, #{ <<"error">> => #{ <<"message">> => <<"quota">>,
                                         <<"code">> => <<"rate_limited">> } }}]),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"model_error">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(
        #{ <<"message">> => <<"quota">>, <<"code">> => <<"rate_limited">> },
        maps:get(<<"agent-error-detail">>, Result)
    ),
    {_, BareOpts} = setup([{ok, #{ <<"error">> => #{ <<"param">> => null } }}]),
    Bare = run_agent(#{}, BareOpts),
    ?assertEqual(<<"model_error">>, maps:get(<<"agent-error">>, Bare)),
    ?assertEqual(
        #{ <<"message">> => <<"the response carries an error">> },
        maps:get(<<"agent-error-detail">>, Bare)
    ).

invalid_response_test() ->
    lists:foreach(
        fun(Reply) ->
            {_Table, Opts} = setup([Reply]),
            Result = run_agent(#{}, Opts),
            ?assertEqual(<<"invalid_response">>, maps:get(<<"agent-error">>, Result)),
            ?assert(is_binary(
                maps:get(<<"message">>, maps:get(<<"agent-error-detail">>, Result))))
        end,
        [
            {raw, <<"not json">>},
            {raw, <<"[1,2]">>},
            {ok, #{ <<"choices">> => [] }},
            {ok, #{ <<"choices">> => [#{ <<"finish_reason">> => <<"stop">> }] }}
        ]
    ).

inference_device_failure_test() ->
    Crashing =
        #{ <<"completions">> =>
            fun(_, _, _) -> error({runtime_down, <<"http://10.0.0.7:30001">>}) end },
    Result = run_agent(#{}, #{ <<"agent-inference-device">> => Crashing }),
    ?assertEqual(<<"model_error">>, maps:get(<<"agent-error">>, Result)),
    ?assertEqual(<<"The model call failed.">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual(1, maps:get(<<"agent-iterations">>, Result)),
    ?assertEqual(
        #{ <<"message">> => <<"the inference call raised an exception">> },
        maps:get(<<"agent-error-detail">>, Result)
    ).

inference_error_terms_are_not_shown_test() ->
    Detail = fun(Reply) ->
        {_Table, Opts} = setup([Reply]),
        maps:get(<<"agent-error-detail">>, run_agent(#{}, Opts))
    end,
    ?assertEqual(#{ <<"message">> => <<"timeout">> }, Detail({error, timeout})),
    ?assertEqual(
        #{ <<"message">> => <<"the inference call failed">> },
        Detail({error, {connect_failed, <<"http://10.0.0.7:30001">>}})
    ),
    ?assertEqual(
        #{ <<"message">> => <<"the inference call failed">> },
        Detail({error, #{ <<"peer">> => <<"http://10.0.0.7:30001">> }})
    ).

%%% Routing and authority.

routing_comes_from_node_options_only_test() ->
    {Table, Opts} = setup([answer_reply(<<"ok">>)]),
    {OtherTable, Other} = setup([answer_reply(<<"wrong device">>)]),
    Hostile = #{
        <<"agent-inference-device">> => maps:get(<<"agent-inference-device">>, Other),
        <<"agent-tool-devices">> => #{ <<"http_request">> => <<"relay@1.0">> },
        <<"agent-api-peer">> => <<"http://127.0.0.1:1">>,
        <<"agent-api-path">> => <<"/steal">>,
        <<"agent-api-key">> => <<"secret">>,
        <<"inference-peer">> => <<"http://127.0.0.1:1">>
    },
    Base = maps:merge(#{ <<"device">> => <<"agent@1.0">> }, Hostile),
    Result = run_agent(Base, Hostile, Opts),
    ?assertEqual(<<"ok">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual([], model_requests(OtherTable)),
    [{_, _, InfBase, InfReq, InfOpts}] = ets:tab2list(Table),
    ?assertEqual([<<"device">>], maps:keys(InfBase)),
    ?assertEqual([<<"body">>, <<"path">>], lists:sort(maps:keys(InfReq))),
    lists:foreach(
        fun(Key) -> ?assertNot(maps:is_key(Key, InfOpts)) end,
        [<<"agent-api-peer">>, <<"agent-api-path">>, <<"agent-api-key">>,
         <<"inference-peer">>]
    ),
    [Request] = model_requests(Table),
    ?assertEqual(
        [<<"messages">>, <<"tool_choice">>, <<"tools">>],
        lists:sort(maps:keys(Request))
    ).

default_model_test() ->
    Model = fun(ReqKeys, ExtraOpts) ->
        {Table, Opts} = setup([answer_reply(<<"ok">>)], ExtraOpts),
        _ = run_agent(ReqKeys, Opts),
        [Request] = model_requests(Table),
        maps:get(<<"model">>, Request, absent)
    end,
    ?assertEqual(absent, Model(#{}, #{})),
    ?assertEqual(
        <<"node-model">>,
        Model(#{}, #{ <<"agent-default-model">> => <<"node-model">> })
    ),
    ?assertEqual(
        <<"caller-model">>,
        Model(#{ <<"agent-model">> => <<"caller-model">> },
              #{ <<"agent-default-model">> => <<"node-model">> })
    ).

%%% Tool set, prompt and choice.

system_prompt_lists_enabled_tools_test() ->
    {Table, Opts} = setup([answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    [Request] = model_requests(Table),
    [#{ <<"content">> := Prompt } | _] = maps:get(<<"messages">>, Request),
    lists:foreach(
        fun(Name) -> ?assert(contains(Prompt, <<"- ", Name/binary, ":">>)) end,
        [<<"http_request">>, <<"lookup_data">>, <<"search_messages">>,
         <<"get_arweave_tx">>]
    ),
    ?assertNot(contains(Prompt, <<"bundle_item">>)).

disabled_tools_test() ->
    {Table, Opts} = setup([answer_reply(<<"pong">>)]),
    Result =
        run_agent(
            #{ <<"agent-disable-tools">> => <<"true">>,
               <<"agent-tool-choice">> => <<"required">> },
            Opts
        ),
    ?assertEqual(<<"pong">>, maps:get(<<"agent-answer">>, Result)),
    [Request] = model_requests(Table),
    ?assertNot(maps:is_key(<<"tools">>, Request)),
    ?assertNot(maps:is_key(<<"tool_choice">>, Request)),
    [#{ <<"content">> := Prompt } | _] = maps:get(<<"messages">>, Request),
    ?assertNot(contains(Prompt, <<"tool">>)),
    ?assertNot(contains(Prompt, <<"http_request">>)).

system_prompt_override_test() ->
    {Table, Opts} = setup([answer_reply(<<"ok">>)]),
    _ = run_agent(#{ <<"agent-system-prompt">> => <<"Be terse.">> }, Opts),
    [Request] = model_requests(Table),
    ?assertEqual(
        #{ <<"role">> => <<"system">>, <<"content">> => <<"Be terse.">> },
        hd(maps:get(<<"messages">>, Request))
    ).

agent_tools_selects_a_subset_test() ->
    Calls = [
        http_call(<<"h">>),
        tool_call(<<"l">>, <<"lookup_data">>, #{ <<"id">> => binary:copy(<<"a">>, 43) })
    ],
    {Table, Opts} = setup([tool_reply(Calls), answer_reply(<<"ok">>)]),
    _ = run_agent(#{ <<"agent-tools">> => <<"lookup_data, unknown_tool">> }, Opts),
    [First, Second] = model_requests(Table),
    ?assertEqual(
        [<<"lookup_data">>],
        [Name || #{ <<"function">> := #{ <<"name">> := Name } }
            <- maps:get(<<"tools">>, First)]
    ),
    ?assertEqual([], tool_requests(Table, http)),
    ?assertEqual(1, length(tool_requests(Table, lookup))),
    [HttpResult, _] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(HttpResult, <<"`http_request` was not executed">>)),
    Names = fun(Value) ->
        Tools = enabled_tools(#{ <<"agent-tools">> => Value }, #{}),
        [Name || #{ name := Name } <- Tools]
    end,
    ?assertEqual([<<"http_request">>, <<"get_arweave_tx">>],
                 Names([<<"get_arweave_tx">>, <<"http_request">>])),
    ?assertEqual([<<"search_messages">>], Names(<<"[\"search_messages\"]">>)),
    ?assertEqual([], Names(<<"unknown_tool">>)),
    ?assertEqual([], Names(<<"bundle_item">>)),
    ?assertEqual([], Names(<<>>)),
    ?assertEqual([], Names([])),
    ?assertEqual([], Names(<<"[]">>)),
    ?assertEqual(4, length(Names(#{}))).

invalid_utf8_inputs_test() ->
    {Table, Opts} = setup([answer_reply(<<"ok">>)]),
    Result =
        run_agent(
            #{ <<"agent-disable-tools">> => <<"tr", 255, "ue">>,
               <<"agent-tools">> => <<"lookup_data,", 255, " b">>,
               <<"agent-max-iterations">> => <<"2", 255>> },
            Opts
        ),
    ?assertEqual(<<"ok">>, maps:get(<<"agent-answer">>, Result)),
    [Request] = model_requests(Table),
    ?assertEqual(
        [<<"lookup_data">>],
        [Name || #{ <<"function">> := #{ <<"name">> := Name } }
            <- maps:get(<<"tools">>, Request)]
    ),
    Names = [Name || #{ name := Name }
                <- enabled_tools(
                       #{ <<"agent-tools">> => [<<"http_request">>, <<255>>] }, #{})],
    ?assertEqual([<<"http_request">>], Names).

bundle_item_is_disabled_by_default_test() ->
    Call = tool_call(<<"b">>, <<"bundle_item">>, #{ <<"data">> => <<"hello">> }),
    {Table, Opts} = setup([tool_reply([Call]), answer_reply(<<"ok">>)]),
    _ = run_agent(#{ <<"agent-tools">> => <<"bundle_item,http_request">> }, Opts),
    [First, Second] = model_requests(Table),
    ?assertEqual(
        [<<"http_request">>],
        [Name || #{ <<"function">> := #{ <<"name">> := Name } }
            <- maps:get(<<"tools">>, First)]
    ),
    ?assertEqual([], tool_requests(Table, bundle)),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Content, <<"`bundle_item` was not executed">>)).

bundle_item_when_enabled_test() ->
    Call =
        tool_call(<<"b">>, <<"bundle_item">>,
            #{ <<"data">> => <<"hello">>, <<"content_type">> => <<"text/markdown">> }),
    {Table, Opts} =
        setup(
            [tool_reply([Call]), answer_reply(<<"Stored.">>)],
            #{ <<"agent-allow-bundle">> => true, <<"priv-wallet">> => ar_wallet:new() }
        ),
    Result = run_agent(#{}, Opts),
    ?assertEqual(<<"Stored.">>, maps:get(<<"agent-answer">>, Result)),
    [First, Second] = model_requests(Table),
    ?assert(lists:member(
        <<"bundle_item">>,
        [Name || #{ <<"function">> := #{ <<"name">> := Name } }
            <- maps:get(<<"tools">>, First)]
    )),
    [BundleReq] = tool_requests(Table, bundle),
    Item = maps:get(<<"item">>, BundleReq),
    ?assertEqual(<<"hello">>, maps:get(<<"data">>, Item)),
    ?assertEqual(<<"text/markdown">>, maps:get(<<"content-type">>, Item)),
    ?assert(maps:is_key(<<"commitments">>, Item)),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Content, <<"Submitted data item ">>)).

tool_choice_passthrough_test() ->
    Choice = fun(Value) ->
        {Table, Opts} =
            setup([tool_reply([http_call(<<"c">>)]), answer_reply(<<"ok">>)]),
        _ = run_agent(#{ <<"agent-tool-choice">> => Value }, Opts),
        [maps:get(<<"tool_choice">>, Request) || Request <- model_requests(Table)]
    end,
    Named = #{ <<"type">> => <<"function">>,
               <<"function">> => #{ <<"name">> => <<"http_request">> } },
    ?assertEqual([<<"required">>, <<"auto">>], Choice(<<"required">>)),
    ?assertEqual([Named, <<"auto">>], Choice(hb_json:encode(Named))),
    ?assertEqual([Named, <<"auto">>], Choice(Named)),
    ?assertEqual([<<"auto">>, <<"auto">>], Choice(<<"sometimes">>)),
    Disabled = #{ <<"type">> => <<"function">>,
                  <<"function">> => #{ <<"name">> => <<"bundle_item">> } },
    ?assertEqual([<<"auto">>, <<"auto">>], Choice(Disabled)).

tool_choice_none_executes_nothing_test() ->
    {Table, Opts} =
        setup([tool_reply([http_call(<<"c">>)]), answer_reply(<<"No tools.">>)]),
    Result = run_agent(#{ <<"agent-tool-choice">> => <<"none">> }, Opts),
    ?assertEqual(<<"No tools.">>, maps:get(<<"agent-answer">>, Result)),
    ?assertEqual([], tool_requests(Table, http)),
    [First, Second] = model_requests(Table),
    ?assertEqual(<<"none">>, maps:get(<<"tool_choice">>, First)),
    ?assertEqual(<<"none">>, maps:get(<<"tool_choice">>, Second)),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Content, <<"the tool choice of this run is none">>)).

%%% Conversation inputs.

agent_messages_test() ->
    Messages = [
        #{ <<"role">> => <<"system">>, <<"content">> => <<"Custom system.">> },
        #{ <<"role">> => <<"user">>, <<"content">> => <<"Earlier question">> },
        #{ <<"role">> => <<"assistant">>, <<"content">> => <<"Earlier answer">> },
        #{ <<"role">> => <<"user">>, <<"content">> => <<"Follow-up">> }
    ],
    FirstMessages = fun(Value) ->
        {Table, Opts} = setup([answer_reply(<<"ok">>)]),
        _ = run_agent(#{ <<"agent-messages">> => Value }, Opts),
        [Request] = model_requests(Table),
        maps:get(<<"messages">>, Request)
    end,
    ?assertEqual(Messages, FirstMessages(hb_json:encode(Messages))),
    ?assertEqual(Messages, FirstMessages(Messages)),
    ?assertEqual(
        Messages,
        FirstMessages(maps:from_list(
            lists:zip([<<"1">>, <<"2">>, <<"3">>, <<"4">>], Messages)))
    ),
    [System | Rest] = FirstMessages(tl(Messages)),
    ?assertEqual(<<"system">>, maps:get(<<"role">>, System)),
    ?assertEqual(tl(Messages), Rest),
    lists:foreach(
        fun(Invalid) ->
            ?assertEqual(
                [<<"system">>, <<"user">>],
                [Role || #{ <<"role">> := Role } <- FirstMessages(Invalid)]
            )
        end,
        [<<"[not json">>, <<"[]">>, <<"{\"role\":\"user\"}">>,
         [#{ <<"role">> => <<"wizard">>, <<"content">> => <<"x">> }]]
    ).

reasoning_content_is_preserved_test() ->
    Reply =
        reply_with(
            #{ <<"content">> => null,
               <<"reasoning_content">> => <<"I should fetch the page.">>,
               <<"tool_calls">> => [http_call(<<"c">>)] },
            <<"tool_calls">>),
    {Table, Opts} = setup([Reply, answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    [_, Second] = model_requests(Table),
    [Assistant] =
        [M || M = #{ <<"role">> := <<"assistant">> }
            <- maps:get(<<"messages">>, Second)],
    ?assertEqual(
        <<"I should fetch the page.">>,
        maps:get(<<"reasoning_content">>, Assistant)
    ).

%%% Executors.

http_request_refuses_non_public_hosts_test() ->
    Refused = [
        <<"http://127.0.0.1/">>, <<"http://localhost:8734/~meta@1.0/info">>,
        <<"http://LOCALHOST./">>, <<"http://api.localhost/">>,
        <<"http://10.1.2.3/">>, <<"http://172.16.0.1/">>,
        <<"http://192.168.1.1/">>, <<"http://169.254.169.254/latest/meta-data">>,
        <<"http://0.0.0.0/">>, <<"http://[::1]/">>, <<"http://[fe80::1]/">>,
        <<"http://[::ffff:127.0.0.1]/">>, <<"http://2130706433/">>,
        <<"http://127.1/">>
    ],
    lists:foreach(
        fun(Url) ->
            ?assertMatch({rejected, _}, check_url(Url, #{}))
        end,
        Refused
    ),
    lists:foreach(
        fun(Url) -> ?assertMatch({rejected, _}, check_url(Url, #{})) end,
        [<<"ftp://example.com/">>, <<"file:///etc/hosts">>, <<"example.com">>,
         <<"/relative">>, <<"https://">>]
    ),
    ?assertEqual(ok, check_url(<<"https://example.com/path?q=1">>, #{})),
    ?assertEqual(ok, check_url(<<"http://8.8.8.8/">>, #{})),
    Allow = #{ <<"agent-http-allow-private">> => true },
    ?assertEqual(ok, check_url(<<"http://127.0.0.1:8734/">>, Allow)),
    ?assertMatch({rejected, _}, check_url(<<"ftp://127.0.0.1/">>, Allow)),
    Call = tool_call(<<"c">>, <<"http_request">>,
        #{ <<"url">> => <<"http://169.254.169.254/">> }),
    {Table, Opts} = setup([tool_reply([Call]), answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    ?assertEqual([], tool_requests(Table, http)),
    [_, Second] = model_requests(Table),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Content, <<"special-use address">>)).

http_request_body_and_method_test() ->
    Calls = [
        tool_call(<<"p">>, <<"http_request">>,
            #{ <<"url">> => <<"https://example.com/post">>, <<"method">> => <<"post">>,
               <<"body">> => <<"x=1">> }),
        tool_call(<<"j">>, <<"http_request">>,
            #{ <<"url">> => <<"https://example.com/json">>, <<"method">> => <<"PUT">>,
               <<"body">> => #{ <<"a">> => 1 } }),
        tool_call(<<"m">>, <<"http_request">>,
            #{ <<"url">> => <<"https://example.com/">>, <<"method">> => <<"TRACE">> }),
        tool_call(<<"n">>, <<"http_request">>,
            #{ <<"url">> => <<"https://example.com/n">>, <<"method">> => null })
    ],
    {Table, Opts} = setup([tool_reply(Calls), answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    [Post, Put, Default] = [P || #{ <<"payload">> := P } <- tool_requests(Table, http)],
    ?assertEqual(<<"GET">>, maps:get(<<"method">>, Default)),
    ?assertEqual(
        #{ <<"path">> => <<"https://example.com/post">>, <<"method">> => <<"POST">>,
           <<"body">> => <<"x=1">>, <<"content-type">> => <<"text/plain">> },
        Post
    ),
    ?assertEqual(<<"application/json">>, maps:get(<<"content-type">>, Put)),
    ?assertEqual(<<"{\"a\":1}">>, maps:get(<<"body">>, Put)),
    [_, Second] = model_requests(Table),
    [_, _, Trace, _] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Trace, <<"method must be GET, POST, PUT or DELETE">>)).

tool_results_are_bounded_test() ->
    Big = #{ <<"call">> =>
        fun(_, _, _) ->
            {ok, #{ <<"status">> => 200, <<"body">> => binary:copy(<<"y">>, 10000) }}
        end },
    {Table, Opts0} =
        setup([tool_reply([http_call(<<"c">>)]), answer_reply(<<"ok">>)],
              #{ <<"agent-max-tool-result-bytes">> => 100 }),
    Opts = Opts0#{ <<"agent-tool-devices">> => #{ <<"http_request">> => Big } },
    _ = run_agent(#{}, Opts),
    [_, Second] = model_requests(Table),
    [Content] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assert(contains(Content, <<"[truncated: 100 of ">>)),
    ?assert(byte_size(Content) < 150).

lookup_and_arweave_executors_test() ->
    ID = <<"abcdefghijklmnopqrstuvwxyzABCDEFGHIJ-_01234">>,
    Calls = [
        tool_call(<<"l">>, <<"lookup_data">>, #{ <<"id">> => ID }),
        tool_call(<<"t">>, <<"get_arweave_tx">>, #{ <<"id">> => ID }),
        tool_call(<<"x">>, <<"lookup_data">>, #{ <<"id">> => <<"../../etc">> })
    ],
    {Table, Opts} = setup([tool_reply(Calls), answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    [Lookup] = tool_requests(Table, lookup),
    ?assertEqual(#{ <<"path">> => <<"read">>, <<"read">> => ID }, Lookup),
    [Tx] = tool_requests(Table, arweave),
    ?assertEqual(
        #{ <<"path">> => <<"tx">>, <<"tx">> => ID, <<"method">> => <<"GET">>,
           <<"exclude-data">> => true },
        Tx
    ),
    [_, Second] = model_requests(Table),
    [LookupResult, TxResult, Invalid] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assertEqual(<<"{\"data\":\"cached\"}">>, LookupResult),
    ?assertEqual(<<"{\"owner\":\"someone\"}">>, TxResult),
    ?assert(contains(Invalid, <<"43-character base64url ID">>)).

search_executor_test() ->
    Calls = [
        tool_call(<<"s">>, <<"search_messages">>,
            #{ <<"match">> => #{ <<"type">> => <<"Process">> },
               <<"return">> => <<"count">> }),
        tool_call(<<"n">>, <<"search_messages">>,
            #{ <<"match">> => #{ <<"nested">> => #{ <<"a">> => 1 } } }),
        tool_call(<<"r">>, <<"search_messages">>,
            #{ <<"match">> => #{ <<"a">> => 1 }, <<"return">> => <<"everything">> }),
        tool_call(<<"f">>, <<"search_messages">>,
            #{ <<"match">> => #{ <<"ratio">> => 1.5, <<"live">> => true } })
    ],
    {Table, Opts} = setup([tool_reply(Calls), answer_reply(<<"ok">>)]),
    _ = run_agent(#{}, Opts),
    [Search, Numbers] = tool_requests(Table, search),
    ?assertEqual(
        #{ <<"path">> => <<"only">>, <<"only">> => #{ <<"type">> => <<"Process">> },
           <<"return">> => <<"count">> },
        Search
    ),
    ?assertEqual(
        #{ <<"ratio">> => 1.5, <<"live">> => true },
        maps:get(<<"only">>, Numbers)
    ),
    [_, Second] = model_requests(Table),
    [Found, Nested, Return, _] = tool_contents(maps:get(<<"messages">>, Second)),
    ?assertEqual(<<"[\"path-a\",\"path-b\"]">>, Found),
    ?assert(contains(Nested, <<"was not executed">>)),
    ?assert(contains(Return, <<"return must be paths, messages or count">>)).

%%% Text helpers.

bound_text_test() ->
    ?assertEqual(<<"short">>, bound_text(<<"short">>, 10)),
    Text = binary:copy(<<16#20AC/utf8>>, 10),
    Bounded = bound_text(Text, 10),
    [Kept, _] = binary:split(Bounded, <<"\n[truncated">>),
    ?assertEqual(binary:copy(<<16#20AC/utf8>>, 3), Kept),
    ?assert(contains(Bounded, <<"[truncated: 9 of 30 bytes shown]">>)),
    ?assertEqual(<<"a", 16#FFFD/utf8, "b">>, bound_text(<<"a", 255, "b">>, 10)),
    Binary = <<0, 255, 254, 253, 252, 251>>,
    Safe = bound_text(Binary, 4),
    ?assertEqual(Safe, unicode:characters_to_binary(Safe)),
    ?assert(json_encodable(#{ <<"content">> => Safe })).

truthy_test() ->
    lists:foreach(fun(V) -> ?assert(truthy(V)) end,
        [true, 1, <<"true">>, <<"TRUE">>, <<"1">>, <<" true ">>]),
    lists:foreach(fun(V) -> ?assertNot(truthy(V)) end,
        [false, 0, <<"false">>, <<"yes">>, not_found, <<>>, <<"tr", 255, "ue">>,
         <<"1", 255>>]).

%%% Live check. It runs only when AGENT_TEST_INFERENCE_PEER names an
%%% OpenAI-compatible runtime; AGENT_TEST_INFERENCE_PATH,
%%% AGENT_TEST_INFERENCE_API_KEY and AGENT_TEST_MODEL are optional. The runtime
%%% is configured through inference@1.0 node options; the request carries no
%%% backend settings.
live_inference_test_() ->
    {timeout, 120, fun() ->
        case os:getenv("AGENT_TEST_INFERENCE_PEER") of
            false ->
                ?debugMsg(
                    "Skipping live agent test: AGENT_TEST_INFERENCE_PEER is not set");
            Peer ->
                live_inference(list_to_binary(Peer))
        end
    end}.

live_inference(Peer) ->
    Optional =
        fun(Env, Key) ->
            case os:getenv(Env) of
                false -> #{};
                Value -> #{ Key => list_to_binary(Value) }
            end
        end,
    Opts =
        lists:foldl(
            fun maps:merge/2,
            #{ <<"inference-peer">> => Peer },
            [
                Optional("AGENT_TEST_INFERENCE_PATH", <<"inference-path">>),
                Optional("AGENT_TEST_INFERENCE_API_KEY", <<"inference-api-key">>),
                Optional("AGENT_TEST_MODEL", <<"agent-default-model">>)
            ]
        ),
    {ok, Result} =
        run(
            #{ <<"device">> => <<"agent@1.0">> },
            #{
                <<"path">> => <<"run">>,
                <<"agent-user-prompt">> => <<"Reply with the single word pong.">>,
                <<"agent-disable-tools">> => true,
                <<"agent-max-iterations">> => 2
            },
            Opts
        ),
    ?debugFmt("Live agent result: ~p", [Result]),
    ?assertNot(maps:is_key(<<"agent-error">>, Result)),
    ?assert(byte_size(maps:get(<<"agent-answer">>, Result)) > 0).

-endif.
