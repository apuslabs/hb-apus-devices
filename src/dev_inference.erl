%%% @doc `inference@1.0': OpenAI-compatible inference served by an
%%% operator-configured model runtime.
%%%
%%% The device relays chat completions, the model list and a health probe to
%%% one OpenAI-compatible runtime through `relay@1.0'. The runtime's origin,
%%% request paths and credential are node options: neither the request nor
%%% the base message can select them. Results are complete messages, so the
%%% device rejects `stream=true'.
%%%
%%% With `tee=true' the device records the public generation request, the
%%% runtime's response and the AO-Core execution link in a JSON document
%%% (`raw'), and asks the operator's attestation device (`sev_gpu@1.0' by
%%% default) for a report bound to the SHA-256 of exactly those bytes.
-module(dev_inference).
-implements(<<"inference@1.0">>).
-specification("docs/spec/inference.md").
-export([info/1, completions/3, chat/3, v1/3, models/3, health/3]).
-include_lib("hb/include/hb.hrl").

%% Node option defaults.
-define(DEFAULT_PEER, <<"http://localhost:30001">>).
-define(DEFAULT_PATH, <<"/v1/chat/completions">>).
-define(DEFAULT_MODELS_PATH, <<"/v1/models">>).
-define(DEFAULT_HEALTH_PATH, <<"/health">>).
-define(DEFAULT_ATTESTATION_DEVICE, <<"sev_gpu@1.0">>).

-define(JSON, <<"application/json">>).

%% OpenAI-compatible generation parameters relayed to the runtime. The same
%% list without `user' is the generation part of the request allowlist of
%% `inference_receipt@1.0'; both specifications state it.
-define(PARAM_KEYS, [
    <<"model">>, <<"prompt">>, <<"messages">>, <<"max_tokens">>,
    <<"max_completion_tokens">>, <<"temperature">>, <<"top_p">>, <<"n">>,
    <<"stream">>, <<"stop">>, <<"presence_penalty">>,
    <<"frequency_penalty">>, <<"logit_bias">>, <<"user">>, <<"seed">>,
    <<"top_k">>, <<"repetition_penalty">>, <<"length_penalty">>,
    <<"early_stopping">>, <<"tools">>, <<"tool_choice">>,
    <<"response_format">>, <<"chat_template_kwargs">>, <<"reasoning_effort">>
]).

%% Generation inputs that may appear in the published attestation. `user' is
%% a caller identifier that does not affect sampling, so it is withheld.
-define(PUBLIC_PARAM_KEYS, ?PARAM_KEYS -- [<<"user">>]).

%% Model and runtime facts an operator declares under the `inference-opts'
%% node option. Only these keys are reported in `resolved_model'.
-define(MODEL_FACT_KEYS, [
    <<"model_name">>, <<"model_revision">>, <<"model_sha256">>,
    <<"runtime_name">>, <<"runtime_version">>, <<"runtime_build_hash">>,
    <<"precision">>, <<"deterministic">>
]).

%%% Device API

%% @doc Return the device description. `exports' lists every resolvable key.
info(_Opts) ->
    #{
        exports => [<<"completions">>, <<"chat">>, <<"v1">>, <<"models">>,
            <<"health">>],
        description =>
            <<"OpenAI-compatible inference relayed to an operator-configured "
              "runtime">>,
        version => <<"1.0">>
    }.

%% @doc Run one non-streaming chat completion on the configured runtime.
-spec completions(
    #{ _ => _ },
    #{
        body => _,
        model => _,
        messages => _,
        prompt => _,
        tools => _,
        temperature => _,
        stream => _,
        tee => _,
        _ => _
    },
    map()
) -> {ok, #{ _ => _ }} | {error, #{ _ => _ }}.
completions(Base, Req, Opts) ->
    case streaming_requested(Req, Opts) of
        true ->
            reply(error, 400, ?JSON,
                error_json(<<"invalid_request_error">>,
                    <<"streaming_unsupported">>,
                    <<"inference@1.0 returns complete responses; "
                      "send stream=false or omit stream.">>),
                #{}, Req, Opts);
        false ->
            complete(Base, Req, Opts)
    end.

%% @doc Route `/chat/completions' to `completions': the request is merged into
%% the base message, which keeps this device and gains `chat-mode: true'.
-spec chat(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ _ => _ }}.
chat(Base, Req, Opts) ->
    {ok, hb_util:deep_merge(
        Base,
        Req#{
            <<"device">> => <<"inference@1.0">>,
            <<"chat-mode">> => true
        },
        Opts
    )}.

%% @doc Route the OpenAI `/v1/...' prefix: the request is merged into the base
%% message, which keeps this device, so the next path segment resolves here.
-spec v1(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ _ => _ }}.
v1(Base, Req, Opts) ->
    {ok, hb_util:deep_merge(
        Base,
        Req#{
            <<"device">> => <<"inference@1.0">>
        },
        Opts
    )}.

%% @doc Return the runtime's model list, unchanged.
-spec models(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ status := integer(), body := binary(), _ => _ }}
    | {error, #{ status := integer(), body := binary(), _ => _ }}.
models(_Base, _Req, Opts) ->
    case runtime_request(<<"GET">>, <<"inference-models-path">>,
            ?DEFAULT_MODELS_PATH, undefined, Opts) of
        {ok, Res} ->
            {ok, #{
                <<"status">> => success_status(Res, Opts),
                <<"content-type">> => response_content_type(Res, Opts),
                <<"body">> => response_body(Res, Opts)
            }};
        {error, Status, Body, Extra} ->
            {error, Extra#{
                <<"status">> => Status,
                <<"content-type">> => ?JSON,
                <<"body">> => Body
            }}
    end.

%% @doc Probe the runtime's health endpoint. A 2xx answer is healthy.
-spec health(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ healthy := true, _ => _ }}
    | {error, #{ status := integer(), body := binary(), _ => _ }}.
health(_Base, _Req, Opts) ->
    case runtime_request(<<"GET">>, <<"inference-health-path">>,
            ?DEFAULT_HEALTH_PATH, undefined, Opts) of
        {ok, Res} ->
            {ok, #{
                <<"healthy">> => true,
                <<"runtime-status">> => success_status(Res, Opts),
                <<"checked-at">> => os:system_time(millisecond)
            }};
        {error, Status, Body, Extra} ->
            {error, Extra#{
                <<"status">> => Status,
                <<"content-type">> => ?JSON,
                <<"body">> => Body
            }}
    end.

%%% Completions

%% Send the generation request and shape the runtime's answer.
complete(Base, Req, Opts) ->
    Payload = backend_payload(Req, Opts),
    case runtime_request(<<"POST">>, <<"inference-path">>, ?DEFAULT_PATH,
            Payload, Opts) of
        {ok, Res} ->
            case truthy(hb_ao:get(<<"tee">>, Req, false, Opts)) of
                true -> attested_response(Res, Base, Req, Payload, Opts);
                false ->
                    reply(ok, success_status(Res, Opts),
                        response_content_type(Res, Opts),
                        response_body(Res, Opts), #{}, Req, Opts)
            end;
        {error, Status, Body, Extra} ->
            reply(error, Status, ?JSON, Body, Extra, Req, Opts)
    end.

%% A request streams when `stream' is truthy as a message key or inside a
%% JSON `body'.
streaming_requested(Req, Opts) ->
    truthy(hb_ao:get(<<"stream">>, Req, false, Opts)) orelse
        truthy(maps:get(<<"stream">>, body_params(Req, Opts), false)).

body_params(Req, Opts) ->
    case hb_ao:get(<<"body">>, Req, not_found, Opts) of
        Bin when is_binary(Bin) ->
            case decode_object(Bin) of
                {ok, Map} -> Map;
                error -> #{}
            end;
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.

%% The JSON document sent to the runtime: a binary `body' unchanged, a map
%% `body' without AO-Core metadata, or else the generation parameters found
%% on the request message.
backend_payload(Req, Opts) ->
    case hb_ao:get(<<"body">>, Req, not_found, Opts) of
        Body when is_binary(Body) -> Body;
        Body when is_map(Body) ->
            Loaded = hb_cache:ensure_all_loaded(Body, Opts),
            hb_json:encode(
                hb_private:reset(maps:without([<<"commitments">>], Loaded)));
        _ -> hb_json:encode(generation_params(Req, Opts))
    end.

generation_params(Req, Opts) ->
    Params = lists:foldl(
        fun(Key, Acc) ->
            case hb_ao:get(Key, Req, not_found, Opts) of
                not_found -> Acc;
                Value -> Acc#{Key => Value}
            end
        end,
        #{},
        ?PARAM_KEYS
    ),
    hb_cache:ensure_all_loaded(Params, Opts).

%% @doc Build the request recorded in the public attestation from the exact
%% runtime payload. The HTTP message that reached HyperBEAM also carries
%% transport fields (`cf-connecting-ip', `x-forwarded-for', `x-real-ip',
%% `user-agent', cookies, credentials) and the private peer `ip'; none of
%% them is hashed into the nonce or published.
public_request(Req, Body, Opts) ->
    Params = case decode_object(Body) of
        {ok, Decoded} -> maps:with(?PUBLIC_PARAM_KEYS, Decoded);
        error -> #{}
    end,
    case hb_ao:get(<<"tee">>, Req, not_found, Opts) of
        not_found -> Params;
        Tee -> Params#{<<"tee">> => Tee}
    end.

%%% Runtime transport

%% Send one request to the configured runtime and classify the answer (see
%% runtime_response/2). Only node options select the peer, the path and the
%% credential; an unusable `inference-peer' is reported without a request.
runtime_request(Method, PathKey, DefaultPath, Body, Opts) ->
    case runtime_peer(Opts) of
        {ok, Peer} ->
            Path = runtime_path(PathKey, DefaultPath, Opts),
            runtime_response(runtime_call(Method, Peer, Path, Body, Opts), Opts);
        error ->
            misconfigured_peer()
    end.

%% One `relay@1.0' call to `Peer'.
runtime_call(Method, Peer, Path, Body, Opts) ->
    Request0 = #{<<"method">> => Method, <<"path">> => Path},
    Request1 = case Body of
        undefined -> Request0;
        _ -> Request0#{<<"body">> => Body, <<"content-type">> => ?JSON}
    end,
    Request = case hb_opts:get(<<"inference-api-key">>, undefined, Opts) of
        Key when is_binary(Key), byte_size(Key) > 0 ->
            Request1#{<<"authorization">> => <<"Bearer ", Key/binary>>};
        _ -> Request1
    end,
    try
        hb_ao:resolve(
            #{<<"device">> => <<"relay@1.0">>, <<"peer">> => Peer},
            #{
                <<"path">> => <<"call">>,
                <<"target">> => <<"payload">>,
                <<"payload">> => Request
            },
            relay_opts(Opts)
        )
    catch Class:Reason ->
        {error, {Class, Reason}}
    end.

%% @doc The runtime origin `scheme://host:port' taken from `inference-peer'.
%% HyperBEAM's HTTP clients connect to a peer's host and port only and use
%% TLS exactly when the port is 443. A peer is therefore rejected when it has
%% a path other than `/', a query, a fragment or user information, when its
%% host is empty or an IPv6 literal, or when it combines `https' with a port
%% other than 443 or `http' with port 443. A missing port is 80 for `http'
%% and 443 for `https'.
runtime_peer(Opts) ->
    Configured = hb_opts:get(<<"inference-peer">>, ?DEFAULT_PEER, Opts),
    try uri_string:parse(hb_util:bin(Configured)) of
        #{scheme := Scheme, host := Host} = URI
                when is_binary(Scheme), is_binary(Host) ->
            runtime_origin(
                string:lowercase(Scheme),
                Host,
                maps:get(port, URI, undefined),
                maps:without([scheme, host, port], URI)
            );
        _ -> error
    catch _:_ -> error
    end.

runtime_origin(Scheme, Host, Port, Rest) ->
    IsOrigin = Host =/= <<>> andalso binary:match(Host, <<":">>) =:= nomatch
        andalso lists:member(Rest, [#{}, #{path => <<>>}, #{path => <<"/">>}]),
    case {IsOrigin, Scheme, Port} of
        {false, _, _} -> error;
        {true, <<"http">>, undefined} -> origin(Scheme, Host, 80);
        {true, <<"http">>, Explicit}
                when is_integer(Explicit), Explicit > 0, Explicit =/= 443 ->
            origin(Scheme, Host, Explicit);
        {true, <<"https">>, undefined} -> origin(Scheme, Host, 443);
        {true, <<"https">>, 443} -> origin(Scheme, Host, 443);
        _ -> error
    end.

origin(Scheme, Host, Port) ->
    {ok, <<Scheme/binary, "://", Host/binary, ":",
        (integer_to_binary(Port))/binary>>}.

%% A configured request path; a missing leading `/' is added.
runtime_path(Key, Default, Opts) ->
    case hb_util:bin(hb_opts:get(Key, Default, Opts)) of
        <<"/", _/binary>> = Path -> Path;
        Path -> <<"/", Path/binary>>
    end.

%% Runtime calls and attestations are fresh side effects of this step: they
%% are neither looked up in nor written to the result cache, and they carry
%% no HashPath of their own.
auxiliary_opts(Opts) ->
    Opts#{
        <<"hashpath">> => ignore,
        <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
    }.

%% Runtime calls use the node's general HTTP client (`http-client', default
%% `hackney') and therefore its connect and receive timeouts, rather than
%% `relay@1.0''s own client setting.
relay_opts(Opts) ->
    (auxiliary_opts(Opts))#{
        <<"relay-http-client">> =>
            hb_opts:get(<<"http-client">>, hackney, Opts)
    }.

%% Classify a `relay@1.0' result as a 2xx runtime response, a runtime error
%% response (status passed through) or a transport failure (503).
runtime_response({Outcome, Res}, Opts) when is_map(Res) ->
    case {Outcome, response_status(Res, Opts)} of
        {_, Status} when is_integer(Status), Status >= 200, Status < 300 ->
            {ok, Res};
        {_, Status} when is_integer(Status) ->
            runtime_error(Status, Res, Opts);
        {ok, undefined} ->
            {ok, Res};
        _ ->
            unreachable(Res)
    end;
runtime_response(Other, _Opts) ->
    unreachable(Other).

%% A JSON object from the runtime is passed through verbatim; any other body
%% is replaced with an error object. `retry-after' is preserved.
runtime_error(Status, Res, Opts) ->
    Upstream = response_body(Res, Opts),
    Body = case decode_object(Upstream) of
        {ok, _} -> Upstream;
        error ->
            error_json(<<"runtime_error">>, <<"runtime_error">>,
                <<"The inference runtime returned HTTP ",
                    (integer_to_binary(Status))/binary, ".">>)
    end,
    Extra = case hb_maps:get(<<"retry-after">>, Res, undefined, Opts) of
        undefined -> #{};
        RetryAfter -> #{<<"retry-after">> => RetryAfter}
    end,
    {error, error_status(Status), Body, Extra}.

%% The transport failure reason may name internal addresses, so it is logged
%% and never returned.
unreachable(Reason) ->
    ?event(inference, {runtime_unreachable, Reason}),
    {error, 503,
        error_json(<<"runtime_unavailable">>, <<"runtime_unavailable">>,
            <<"The inference runtime is unreachable.">>),
        #{}}.

%% The configured value is not returned: it may name internal addresses.
misconfigured_peer() ->
    ?event(inference, invalid_inference_peer),
    {error, 500,
        error_json(<<"server_error">>, <<"runtime_misconfigured">>,
            <<"The node's inference-peer option is not a supported runtime "
              "origin.">>),
        #{}}.

error_status(Status) when Status >= 400, Status =< 599 -> Status;
error_status(_Status) -> 500.

error_json(Type, Code, Message) ->
    hb_json:encode(#{<<"error">> => #{
        <<"message">> => Message,
        <<"type">> => Type,
        <<"code">> => Code
    }}).

response_status(Res, Opts) ->
    case hb_maps:get(<<"status">>, Res, undefined, Opts) of
        Status when is_integer(Status) -> Status;
        Status when is_binary(Status) ->
            try binary_to_integer(Status) catch _:_ -> undefined end;
        _ -> undefined
    end.

%% A successful relay result without a status is reported as 200.
success_status(Res, Opts) ->
    case response_status(Res, Opts) of
        undefined -> 200;
        Status -> Status
    end.

response_content_type(Res, Opts) ->
    case hb_maps:get(<<"content-type">>, Res, undefined, Opts) of
        ContentType when is_binary(ContentType) -> ContentType;
        _ -> ?JSON
    end.

response_body(Res, Opts) ->
    case hb_maps:get(<<"body">>, Res, <<>>, Opts) of
        Body when is_binary(Body) -> Body;
        Body when is_map(Body); is_list(Body) ->
            hb_json:encode(hb_cache:ensure_all_loaded(Body, Opts));
        _ -> <<>>
    end.

%% Shape a completion result. A request with `type: Message' (an AO process
%% message delivered by the scheduler) receives `data' and `action'; any other
%% caller receives an HTTP-style message.
reply(Outcome, Status, ContentType, Body, Extra, Req, Opts) ->
    case hb_ao:get(<<"type">>, Req, undefined, Opts) of
        <<"Message">> ->
            {Outcome, #{
                <<"data">> => Body,
                <<"action">> => case Outcome of
                    ok -> <<"Inference-Response">>;
                    error -> <<"Inference-Error">>
                end
            }};
        _ ->
            {Outcome, Extra#{
                <<"status">> => Status,
                <<"content-type">> => ContentType,
                <<"body">> => Body
            }}
    end.

%%% Attestation

%% `raw' is published verbatim and the attestation report binds its SHA-256.
%% It records only the public generation request, never the HTTP message.
attested_response(Res, Base, Req, Payload, Opts) ->
    PublicRequest = public_request(Req, Payload, Opts),
    Raw = hb_json:encode(#{
        <<"request">> => PublicRequest,
        <<"response">> => hb_private:reset(Res),
        <<"ao-core">> => ao_core_evidence(Base, Req, Res, Opts),
        <<"timestamp">> => os:system_time(millisecond),
        <<"nonce">> => hb_util:to_hex(crypto:strong_rand_bytes(32))
    }),
    ResponseBody = response_body(Res, Opts),
    Decoded = case decode_object(ResponseBody) of
        {ok, Map} -> Map;
        error -> undefined
    end,
    Additions = #{
        <<"attestation">> => attestation(Raw, Opts),
        <<"resolved_model">> => resolved_model(Decoded, PublicRequest, Opts)
    },
    Enhanced = case Decoded of
        undefined ->
            hb_json:encode(Additions#{<<"response">> => ResponseBody});
        _ ->
            hb_json:encode(maps:merge(Decoded, Additions))
    end,
    reply(ok, success_status(Res, Opts), ?JSON, Enhanced, #{}, Req, Opts).

%% The attestation is the attestation device's result for nonce
%% `hex(SHA-256(Raw))', with `raw' and `nonce' added. When the device fails,
%% only `raw' and `nonce' are present.
attestation(Raw, Opts) ->
    Nonce = hb_util:to_hex(hb_crypto:sha256(Raw)),
    maps:merge(
        attestation_evidence(Nonce, Opts),
        #{<<"raw">> => Raw, <<"nonce">> => Nonce}
    ).

attestation_evidence(Nonce, Opts) ->
    Device = hb_opts:get(<<"inference-attestation-device">>,
        ?DEFAULT_ATTESTATION_DEVICE, Opts),
    try
        evidence_result(
            hb_ao:resolve(
                #{<<"device">> => Device},
                #{<<"path">> => <<"generate">>, <<"nonce">> => Nonce},
                auxiliary_opts(Opts)
            ),
            Opts
        )
    catch Class:Reason ->
        ?event(inference, {attestation_unavailable, {Class, Reason}}),
        #{}
    end.

evidence_result({ok, Result}, Opts) ->
    evidence_map(Result, Opts);
evidence_result(Other, _Opts) ->
    ?event(inference, {attestation_unavailable, Other}),
    #{}.

%% Accept a JSON document, a bare map, or a `{status, body}' envelope.
evidence_map(Bin, _Opts) when is_binary(Bin) ->
    case decode_object(Bin) of
        {ok, Map} -> Map;
        error -> #{}
    end;
evidence_map(Map, Opts) when is_map(Map) ->
    Loaded = hb_cache:ensure_all_loaded(Map, Opts),
    case maps:find(<<"body">>, Loaded) of
        {ok, Body} when is_binary(Body); is_map(Body) ->
            evidence_map(Body, Opts);
        _ ->
            hb_private:reset(maps:without(
                [<<"commitments">>, <<"status">>, <<"content-type">>], Loaded))
    end;
evidence_map(_Other, _Opts) ->
    #{}.

%% @doc Preserve the AO-Core execution link in the public attestation
%% envelope: the HashPath of this step's inputs and the IDs of the request
%% and the runtime response.
ao_core_evidence(Base, Req, Response, Opts) ->
    Hashpath = try hb_path:hashpath(Base, Req, Opts)
    catch _:_ -> undefined
    end,
    #{
        <<"status">> => case Hashpath of
            undefined -> <<"not-captured">>;
            _ -> <<"captured">>
        end,
        <<"source">> => <<"HyperBEAM AO-Core resolve stage 9">>,
        <<"hashpath">> => Hashpath,
        <<"hashpath-algorithm">> => <<"sha-256-chain (AO-Core default)">>,
        <<"request-id">> => safe_message_id(Req, Opts),
        <<"response-id">> => safe_message_id(Response, Opts),
        <<"verification-status">> => <<"captured">>
    }.

safe_message_id(Message, Opts) ->
    case catch hb_message:id(hb_private:reset(Message), none, Opts) of
        ID when is_binary(ID) -> ID;
        _ -> undefined
    end.

%% The model that served this request (the runtime's `model' field, else the
%% requested model, else the configured `model_name') with the operator's
%% declared model and runtime facts.
resolved_model(Response, Request, Opts) ->
    Facts = model_facts(Opts),
    Candidates = [
        case Response of
            #{<<"model">> := ResponseModel} -> ResponseModel;
            _ -> undefined
        end,
        maps:get(<<"model">>, Request, undefined),
        maps:get(<<"model_name">>, Facts, undefined)
    ],
    case [Model || Model <- Candidates, is_binary(Model), Model =/= <<>>] of
        [Model | _] -> Facts#{<<"model">> => Model};
        [] -> Facts
    end.

model_facts(Opts) ->
    case hb_opts:get(<<"inference-opts">>, #{}, Opts) of
        Declared when is_map(Declared) ->
            Loaded = try hb_cache:ensure_all_loaded(Declared, Opts)
            catch _:_ -> Declared
            end,
            lists:foldl(
                fun(Key, Acc) ->
                    case fact_value(Key, Loaded) of
                        undefined -> Acc;
                        null -> Acc;
                        Value -> Acc#{Key => Value}
                    end
                end,
                #{},
                ?MODEL_FACT_KEYS
            );
        _ -> #{}
    end.

%% Facts may be declared with underscores (`model_name') or hyphens.
fact_value(Key, Declared) ->
    case maps:find(Key, Declared) of
        {ok, Value} -> Value;
        error ->
            maps:get(binary:replace(Key, <<"_">>, <<"-">>, [global]),
                Declared, undefined)
    end.

%%% Helpers

decode_object(Bin) when is_binary(Bin) ->
    try hb_json:decode(Bin) of
        Map when is_map(Map) -> {ok, Map};
        _ -> error
    catch _:_ -> error
    end;
decode_object(_) ->
    error.

truthy(true) -> true;
truthy(<<"true">>) -> true;
truthy(<<"1">>) -> true;
truthy(1) -> true;
truthy(_) -> false.

%%% Tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% TEST-NET addresses standing in for the caller and an intermediate proxy.
-define(LEAK_NEEDLES, [
    <<"cf-connecting-ip">>, <<"cf-ipcountry">>, <<"cf-ray">>, <<"cf-visitor">>,
    <<"cdn-loop">>, <<"x-forwarded-for">>, <<"x-forwarded-proto">>,
    <<"x-real-ip">>, <<"true-client-ip">>, <<"forwarded">>, <<"user-agent">>,
    <<"cookie">>, <<"authorization">>,
    <<"203.0.113.77">>, <<"198.51.100.20">>, <<"leak-test-agent">>,
    <<"leak-test-cookie">>, <<"leak-test-token">>, <<"leak-test-user">>,
    <<"a494f31a6eb0fd20">>
]).

-define(CHAT_RESPONSE, <<"{\"id\":\"chatcmpl-test\",\"object\":\"chat.completion\","
    "\"model\":\"runtime-model\",\"choices\":[{\"index\":0,"
    "\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\","
    "\"content\":\"pong\"}}]}">>).

%% An HTTP request as HyperBEAM receives it behind Cloudflare and Nginx.
leaky_request() ->
    #{
        <<"accept">> => <<"*/*">>,
        <<"cdn-loop">> => <<"cloudflare; loops=1">>,
        <<"cf-connecting-ip">> => <<"203.0.113.77">>,
        <<"cf-ipcountry">> => <<"SG">>,
        <<"cf-ray">> => <<"a494f31a6eb0fd20-SIN">>,
        <<"cf-visitor">> => <<"{\"scheme\":\"https\"}">>,
        <<"x-forwarded-for">> => <<"203.0.113.77, 198.51.100.20">>,
        <<"x-forwarded-proto">> => <<"http">>,
        <<"x-real-ip">> => <<"203.0.113.77">>,
        <<"true-client-ip">> => <<"203.0.113.77">>,
        <<"forwarded">> => <<"for=203.0.113.77">>,
        <<"user-agent">> => <<"leak-test-agent">>,
        <<"cookie">> => <<"session=leak-test-cookie">>,
        <<"authorization">> => <<"Bearer leak-test-token">>,
        <<"user">> => <<"leak-test-user">>,
        <<"host">> => <<"hb.apus.network">>,
        <<"method">> => <<"POST">>,
        <<"model">> => <<"test-model">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"max_tokens">> => 4,
        <<"tee">> => true,
        <<"priv">> => #{<<"ip">> => <<"203.0.113.77">>}
    }.

assert_no_transport_leak(Term) ->
    Bin = term_to_binary(Term),
    ?assertEqual([], [Needle || Needle <- ?LEAK_NEEDLES,
        binary:match(Bin, Needle) =/= nomatch]).

chat_request() ->
    #{
        <<"model">> => <<"test-model">>,
        <<"messages">> =>
            [#{<<"role">> => <<"user">>, <<"content">> => <<"ping">>}],
        <<"max_tokens">> => 4
    }.

%% Runtime endpoints answering like an OpenAI-compatible server.
runtime_endpoints() ->
    [
        {"/v1/chat/completions", chat, {200, ?CHAT_RESPONSE}},
        {"/v1/models", models,
            {200, <<"{\"object\":\"list\",\"data\":[{\"id\":\"runtime-model\","
                "\"object\":\"model\",\"owned_by\":\"runtime\"}]}">>}},
        {"/health", health, {200, <<>>}}
    ].

%% Node options for a runtime at `URL', with an isolated store.
runtime_opts(URL) ->
    #{
        <<"inference-peer">> => URL,
        <<"store">> => hb_test_utils:test_store()
    }.

with_runtime(Endpoints, Fun) ->
    {ok, URL, Handle} = hb_mock_server:start(Endpoints),
    try Fun(URL, Handle)
    after hb_mock_server:stop(Handle)
    end.

%% A URL on which nothing listens.
closed_url() ->
    {ok, URL, Handle} = hb_mock_server:start([{"/", unused}]),
    hb_mock_server:stop(Handle),
    timer:sleep(50),
    URL.

%% An attestation device that reports the nonce it was asked to bind.
stub_attestation_device(Parent) ->
    stub_attestation_device(Parent, make_ref()).
stub_attestation_device(Parent, Ref) ->
    #{
        <<"generate">> =>
            fun(_Base, Req, _Opts) ->
                Nonce = hb_maps:get(<<"nonce">>, Req, undefined, #{}),
                Parent ! {attested_nonce, Ref, Nonce},
                {ok, hb_json:encode(#{
                    <<"verified">> => true,
                    <<"claims">> => [#{<<"eat_nonce">> => Nonce}],
                    <<"evidences">> => [<<"stub-evidence">>]
                })}
            end
    }.

decode_body(#{<<"body">> := Body}) -> hb_json:decode(Body).

info_lists_exactly_the_resolvable_keys_test() ->
    #{exports := Exports} = info(#{}),
    ?assertEqual(
        lists:sort([<<"completions">>, <<"chat">>, <<"v1">>, <<"models">>,
            <<"health">>]),
        lists:sort(Exports)),
    [?assert(erlang:function_exported(?MODULE, binary_to_atom(Key), 3))
        || Key <- Exports],
    ?assertNot(erlang:function_exported(?MODULE, stop, 0)).

public_request_keeps_only_generation_inputs_test() ->
    Req = leaky_request(),
    Public = public_request(Req, backend_payload(Req, #{}), #{}),
    ?assertEqual(
        lists:sort([<<"model">>, <<"messages">>, <<"max_tokens">>, <<"tee">>]),
        lists:sort(maps:keys(Public))),
    assert_no_transport_leak(Public).

attestation_raw_excludes_transport_fields_test() ->
    Req = leaky_request(),
    Body = backend_payload(Req, #{}),
    Res = #{<<"status">> => 200, <<"content-type">> => ?JSON,
        <<"body">> => <<"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}">>},
    Opts = #{<<"inference-attestation-device">> =>
        stub_attestation_device(self())},
    {ok, Result} = attested_response(
        Res, #{<<"device">> => <<"inference@1.0">>}, Req, Body, Opts),
    assert_no_transport_leak(Result),
    #{<<"attestation">> := #{<<"raw">> := Raw, <<"nonce">> := Nonce}} =
        decode_body(Result),
    %% The report is requested for this nonce; it must be the digest of the
    %% published `raw' bytes.
    ?assertEqual(Nonce, hb_util:to_hex(hb_crypto:sha256(Raw))),
    ?assertMatch(#{<<"request">> := #{<<"messages">> :=
            [#{<<"content">> := <<"hi">>}]}},
        hb_json:decode(Raw)).

attestation_is_bound_to_the_digest_of_raw_test() ->
    Ref = make_ref(),
    Opts = #{<<"inference-attestation-device">> =>
        stub_attestation_device(self(), Ref)},
    Res = #{<<"status">> => 200, <<"body">> => ?CHAT_RESPONSE},
    {ok, Result} = attested_response(Res, #{}, chat_request(),
        hb_json:encode(chat_request()), Opts),
    Asked = receive {attested_nonce, Ref, N} -> N after 5000 -> no_nonce end,
    #{<<"attestation">> := Attestation, <<"choices">> := [_]} =
        decode_body(Result),
    #{<<"raw">> := Raw, <<"nonce">> := Nonce} = Attestation,
    ?assertEqual(hb_util:to_hex(hb_crypto:sha256(Raw)), Nonce),
    ?assertEqual(Nonce, Asked),
    ?assertEqual(true, maps:get(<<"verified">>, Attestation)),
    ?assertMatch([#{<<"eat_nonce">> := Nonce}],
        maps:get(<<"claims">>, Attestation)).

attestation_accepts_map_and_envelope_results_test() ->
    Evidence = #{<<"verified">> => true, <<"claims">> => []},
    ?assertEqual(Evidence, evidence_map(Evidence, #{})),
    ?assertEqual(Evidence,
        evidence_map(#{<<"status">> => 200, <<"body">> => Evidence}, #{})),
    ?assertEqual(Evidence, evidence_map(#{<<"status">> => 200,
        <<"body">> => hb_json:encode(Evidence)}, #{})),
    ?assertEqual(#{}, evidence_map(<<"not json">>, #{})).

attestation_failure_keeps_raw_and_nonce_test() ->
    Failing = #{<<"generate">> =>
        fun(_Base, _Req, _Opts) -> {error, gpu_unavailable} end},
    Crashing = #{<<"generate">> =>
        fun(_Base, _Req, _Opts) -> error(nvml_mismatch) end},
    Unloadable = #{<<"generate">> =>
        fun(_Base, _Req, _Opts) ->
            {ok, #{<<"claims">> =>
                {link, hb_util:encode(crypto:strong_rand_bytes(32)), #{}}}}
        end},
    lists:foreach(
        fun(Device) ->
            Attestation = attestation(<<"{\"raw\":1}">>,
                #{<<"inference-attestation-device">> => Device}),
            ?assertEqual(lists:sort([<<"nonce">>, <<"raw">>]),
                lists:sort(maps:keys(Attestation))),
            ?assertEqual(hb_util:to_hex(hb_crypto:sha256(<<"{\"raw\":1}">>)),
                maps:get(<<"nonce">>, Attestation))
        end,
        [Failing, Crashing, Unloadable]).

resolved_model_reports_the_served_model_and_declared_facts_test() ->
    Opts = #{<<"inference-opts">> => #{
        <<"model_name">> => <<"configured-model">>,
        <<"model_sha256">> => <<"abc123">>,
        <<"runtime-name">> => <<"runtime">>,
        <<"api_key">> => <<"not-a-model-fact">>
    }},
    Resolved = resolved_model(#{<<"model">> => <<"runtime-model">>},
        #{<<"model">> => <<"requested-model">>}, Opts),
    ?assertEqual(#{
        <<"model">> => <<"runtime-model">>,
        <<"model_name">> => <<"configured-model">>,
        <<"model_sha256">> => <<"abc123">>,
        <<"runtime_name">> => <<"runtime">>
    }, Resolved),
    ?assertEqual(<<"requested-model">>, maps:get(<<"model">>,
        resolved_model(undefined, #{<<"model">> => <<"requested-model">>},
            Opts))),
    ?assertEqual(#{}, resolved_model(undefined, #{}, #{})).

completion_relays_to_the_configured_runtime_test_() ->
    {timeout, 30, fun() ->
        with_runtime(runtime_endpoints(), fun(URL, Handle) ->
            {ok, Result} = completions(#{}, chat_request(), runtime_opts(URL)),
            ?assertEqual(200, maps:get(<<"status">>, Result)),
            ?assertEqual(?CHAT_RESPONSE, maps:get(<<"body">>, Result)),
            [Sent] = hb_mock_server:get_requests(chat, 1, Handle),
            ?assertEqual(chat_request(),
                hb_json:decode(maps:get(<<"body">>, Sent)))
        end)
    end}.

request_and_base_cannot_select_the_runtime_test_() ->
    {timeout, 60, fun() ->
        with_runtime([{"/[...]", diverted}], fun(Diverted, DivertedHandle) ->
            with_runtime(runtime_endpoints(), fun(URL, Handle) ->
                Override = #{
                    <<"agent-api-peer">> => Diverted,
                    <<"agent-api-path">> => <<"/diverted">>,
                    <<"agent-api-key">> => <<"caller-key">>,
                    <<"inference-peer">> => Diverted,
                    <<"inference-path">> => <<"/diverted">>,
                    <<"inference-models-path">> => <<"/diverted">>,
                    <<"inference-health-path">> => <<"/diverted">>,
                    <<"inference-api-key">> => <<"caller-key">>,
                    <<"inference-attestation-device">> => <<"diverted@1.0">>
                },
                Ref = make_ref(),
                Opts = (runtime_opts(URL))#{
                    <<"inference-api-key">> => <<"operator-key">>,
                    <<"inference-attestation-device">> =>
                        stub_attestation_device(self(), Ref)
                },
                Base = Override#{<<"device">> => <<"inference@1.0">>},
                {ok, Attested} = hb_ao:resolve(Base,
                    maps:merge(chat_request(), Override#{
                        <<"path">> => <<"completions">>,
                        <<"tee">> => true
                    }), Opts),
                {ok, _} = hb_ao:resolve(Base,
                    Override#{<<"path">> => <<"models">>}, Opts),
                {ok, _} = hb_ao:resolve(Base,
                    Override#{<<"path">> => <<"health">>}, Opts),
                [Sent] = hb_mock_server:get_requests(chat, 1, Handle),
                ?assertMatch(#{<<"authorization">> := <<"Bearer operator-key">>},
                    maps:get(<<"headers">>, Sent)),
                %% The operator's attestation device answered, not the one
                %% named on the request and the base message.
                #{<<"attestation">> := #{<<"nonce">> := Nonce,
                    <<"verified">> := true}} = decode_body(Attested),
                ?assertEqual(Nonce, receive {attested_nonce, Ref, Asked} -> Asked
                    after 5000 -> no_attestation_request end),
                ?assertMatch([_], hb_mock_server:get_requests(models, 1, Handle)),
                ?assertMatch([_], hb_mock_server:get_requests(health, 1, Handle)),
                ?assertEqual([],
                    hb_mock_server:get_requests(DivertedHandle, diverted))
            end)
        end)
    end}.

streaming_is_rejected_before_the_runtime_is_called_test_() ->
    {timeout, 30, fun() ->
        with_runtime(runtime_endpoints(), fun(URL, Handle) ->
            Opts = runtime_opts(URL),
            {error, Flag} = completions(#{},
                (chat_request())#{<<"stream">> => <<"true">>}, Opts),
            {error, InBody} = completions(#{}, #{<<"body">> =>
                hb_json:encode((chat_request())#{<<"stream">> => true})}, Opts),
            lists:foreach(
                fun(Error) ->
                    ?assertEqual(400, maps:get(<<"status">>, Error)),
                    ?assertMatch(#{<<"error">> :=
                            #{<<"code">> := <<"streaming_unsupported">>}},
                        decode_body(Error))
                end,
                [Flag, InBody]),
            ?assertEqual([], hb_mock_server:get_requests(Handle, chat))
        end)
    end}.

runtime_error_status_is_passed_through_test_() ->
    {timeout, 30, fun() ->
        RateLimited = <<"{\"object\":\"error\",\"message\":\"slow down\","
            "\"code\":429}">>,
        with_runtime(
            [
                {"/v1/chat/completions", chat, {429, RateLimited}},
                {"/v1/models", models, {502, <<"<html>bad gateway</html>">>}},
                {"/health", health, {503, <<>>}}
            ],
            fun(URL, _Handle) ->
                Opts = runtime_opts(URL),
                {error, Chat} = completions(#{}, chat_request(), Opts),
                ?assertEqual(429, maps:get(<<"status">>, Chat)),
                ?assertEqual(RateLimited, maps:get(<<"body">>, Chat)),
                {error, Models} = models(#{}, #{}, Opts),
                ?assertEqual(502, maps:get(<<"status">>, Models)),
                ?assertMatch(#{<<"error">> := #{<<"code">> := <<"runtime_error">>}},
                    decode_body(Models)),
                {error, Health} = health(#{}, #{}, Opts),
                ?assertEqual(503, maps:get(<<"status">>, Health))
            end)
    end}.

retry_after_is_preserved_test() ->
    Res = #{<<"status">> => 429, <<"retry-after">> => <<"7">>,
        <<"body">> => <<"{\"error\":{\"message\":\"later\"}}">>},
    {error, 429, Body, Extra} = runtime_response({error, Res}, #{}),
    ?assertEqual(<<"{\"error\":{\"message\":\"later\"}}">>, Body),
    ?assertEqual(#{<<"retry-after">> => <<"7">>}, Extra),
    {error, Reply} = reply(error, 429, ?JSON, Body, Extra, #{}, #{}),
    ?assertEqual(<<"7">>, maps:get(<<"retry-after">>, Reply)).

runtime_peer_is_an_origin_test() ->
    Peer = fun(URL) -> runtime_peer(#{<<"inference-peer">> => URL}) end,
    ?assertEqual({ok, ?DEFAULT_PEER}, runtime_peer(#{})),
    ?assertEqual({ok, <<"http://runtime.test:8000">>},
        Peer(<<"http://runtime.test:8000/">>)),
    ?assertEqual({ok, <<"http://runtime.test:80">>},
        Peer(<<"HTTP://runtime.test">>)),
    ?assertEqual({ok, <<"https://runtime.test:443">>},
        Peer(<<"https://runtime.test">>)),
    ?assertEqual({ok, <<"https://runtime.test:443">>},
        Peer(<<"https://runtime.test:443/">>)),
    lists:foreach(
        fun(URL) -> ?assertEqual(error, Peer(URL)) end,
        [
            <<"http://runtime.test:8000/openai">>,
            <<"https://runtime.test:8443">>,
            <<"http://runtime.test:443">>,
            <<"http://runtime.test:8000?key=1">>,
            <<"http://user@runtime.test:8000">>,
            <<"http://[::1]:8000">>,
            <<"ftp://runtime.test:21">>,
            <<"runtime.test:8000">>,
            <<"not a url">>
        ]).

runtime_paths_start_with_a_slash_test() ->
    ?assertEqual(<<"/v1/chat/completions">>,
        runtime_path(<<"inference-path">>, ?DEFAULT_PATH, #{})),
    ?assertEqual(<<"/openai/v1/models">>,
        runtime_path(<<"inference-models-path">>, ?DEFAULT_MODELS_PATH,
            #{<<"inference-models-path">> => <<"openai/v1/models">>})).

invalid_peer_is_reported_without_a_request_test() ->
    Opts = #{<<"inference-peer">> => <<"https://runtime.test:8443">>},
    lists:foreach(
        fun(Error) ->
            ?assertEqual(500, maps:get(<<"status">>, Error)),
            ?assertMatch(#{<<"error">> :=
                    #{<<"code">> := <<"runtime_misconfigured">>}},
                decode_body(Error)),
            ?assertEqual(nomatch,
                binary:match(maps:get(<<"body">>, Error), <<"8443">>))
        end,
        [element(2, completions(#{}, chat_request(), Opts)),
            element(2, models(#{}, #{}, Opts)),
            element(2, health(#{}, #{}, Opts))]).

%% A runtime that accepts the connection and never answers is reported as
%% unavailable once the node HTTP client's receive timeout expires.
silent_runtime_times_out_test_() ->
    {timeout, 60, fun() ->
        Silent = fun(_Req) -> timer:sleep(infinity) end,
        with_runtime([{"/health", health, Silent}, {"/v1/models", models, Silent}],
            fun(URL, _Handle) ->
                Opts = (runtime_opts(URL))#{
                    <<"http-client-hackney-recv-timeout">> => 500},
                lists:foreach(
                    fun(Key) ->
                        {Micros, {error, Error}} =
                            timer:tc(?MODULE, Key, [#{}, #{}, Opts]),
                        ?assertEqual(503, maps:get(<<"status">>, Error)),
                        ?assert(Micros < 20000000)
                    end,
                    [health, models])
            end)
    end}.

relay_results_are_classified_test() ->
    Body = <<"{\"ok\":true}">>,
    ?assertEqual({ok, #{<<"body">> => Body}},
        runtime_response({ok, #{<<"body">> => Body}}, #{})),
    ?assertEqual(200, success_status(#{<<"body">> => Body}, #{})),
    ?assertMatch({ok, _},
        runtime_response({created, #{<<"status">> => 201}}, #{})),
    ?assertMatch({error, 500, _, _},
        runtime_response({ok, #{<<"status">> => 302}}, #{})),
    ?assertMatch({error, 503, _, _},
        runtime_response({error, econnrefused}, #{})),
    ?assertMatch({error, 503, _, _},
        runtime_response({error, #{<<"reason">> => <<"closed">>}}, #{})).

unreachable_runtime_returns_503_test_() ->
    {timeout, 30, fun() ->
        Opts = runtime_opts(closed_url()),
        {error, Chat} = completions(#{}, chat_request(), Opts),
        {error, Models} = models(#{}, #{}, Opts),
        {error, Health} = health(#{}, #{}, Opts),
        lists:foreach(
            fun(Error) ->
                ?assertEqual(503, maps:get(<<"status">>, Error)),
                ?assertMatch(#{<<"error">> :=
                        #{<<"code">> := <<"runtime_unavailable">>}},
                    decode_body(Error))
            end,
            [Chat, Models, Health])
    end}.

non_json_runtime_output_is_attested_without_crashing_test_() ->
    {timeout, 30, fun() ->
        with_runtime([{"/v1/chat/completions", chat, {200, <<"plain text">>}}],
            fun(URL, _Handle) ->
                Opts = (runtime_opts(URL))#{
                    <<"inference-attestation-device">> =>
                        stub_attestation_device(self())},
                {ok, Result} = completions(#{},
                    (chat_request())#{<<"tee">> => true}, Opts),
                #{<<"response">> := <<"plain text">>,
                    <<"attestation">> := #{<<"raw">> := Raw,
                        <<"nonce">> := Nonce}} = decode_body(Result),
                ?assertEqual(hb_util:to_hex(hb_crypto:sha256(Raw)), Nonce)
            end)
    end}.

models_and_health_report_the_runtime_test_() ->
    {timeout, 30, fun() ->
        with_runtime(runtime_endpoints(), fun(URL, _Handle) ->
            Opts = runtime_opts(URL),
            {ok, Models} = models(#{}, #{}, Opts),
            ?assertEqual(200, maps:get(<<"status">>, Models)),
            ?assertMatch(#{<<"data">> := [#{<<"id">> := <<"runtime-model">>,
                    <<"owned_by">> := <<"runtime">>}]},
                decode_body(Models)),
            {ok, Health} = health(#{}, #{}, Opts),
            ?assertMatch(#{<<"healthy">> := true, <<"runtime-status">> := 200},
                Health)
        end)
    end}.

message_requests_receive_data_and_action_test() ->
    ?assertEqual({ok, #{<<"data">> => <<"{}">>,
            <<"action">> => <<"Inference-Response">>}},
        reply(ok, 200, ?JSON, <<"{}">>, #{}, #{<<"type">> => <<"Message">>}, #{})),
    ?assertEqual({error, #{<<"data">> => <<"{}">>,
            <<"action">> => <<"Inference-Error">>}},
        reply(error, 503, ?JSON, <<"{}">>, #{}, #{<<"type">> => <<"Message">>}, #{})).

map_body_is_sent_without_commitments_test() ->
    Body = (chat_request())#{<<"commitments">> => #{<<"id">> => #{}}},
    ?assertEqual(chat_request(),
        hb_json:decode(backend_payload(#{<<"body">> => Body}, #{}))).

-endif.
