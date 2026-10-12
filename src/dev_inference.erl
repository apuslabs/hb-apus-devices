%%% @doc Inference device with OpenAI-compatible API.
%%% This module provides an interface to a local Python-based inference server.
-module(dev_inference).
-implements(<<"inference@1.0">>).
-specification("docs/spec/inference.md").
-export([info/1, completions/3, chat/3, models/3, health/3, v1/3, stop/0]).
-include_lib("eunit/include/eunit.hrl").
-include_lib("hb/include/hb.hrl").

-define(SERVER_PORT, "30001").

%% OpenAI-compatible generation parameters relayed to the backend.
-define(PARAM_KEYS, [
    <<"model">>, <<"prompt">>, <<"messages">>, <<"max_tokens">>,
    <<"temperature">>, <<"top_p">>, <<"n">>, <<"stream">>,
    <<"stop">>, <<"presence_penalty">>, <<"frequency_penalty">>,
    <<"logit_bias">>, <<"user">>, <<"seed">>, <<"top_k">>,
    <<"repetition_penalty">>, <<"length_penalty">>, <<"early_stopping">>,
    <<"tools">>, <<"tool_choice">>
]).

%% Generation inputs that may appear in the published attestation. `user' is
%% a caller identifier that does not affect sampling, so it is withheld. Keep
%% this list in sync with `dev_inference_receipt:execution_request/3'.
-define(PUBLIC_PARAM_KEYS, ?PARAM_KEYS -- [<<"user">>]).

%% Device API

%% @doc Return information about the device.
info(_Opts) ->
    #{
        exports => [<<"completions">>, <<"chat">>, <<"models">>, <<"health">>, <<"v1">>],
        description => <<"Inference device with OpenAI-compatible API">>,
        version => <<"1.0">>
    }.

%% @doc Stop the inference server process.
stop() ->
    case whereis(inference_server) of
        undefined -> ok;
        Pid -> 
            Pid ! stop,
            unregister(inference_server),
            ok
    end.

%% @doc Handle completion requests.
-spec completions(
    #{ _ => _ },
    #{
        body => _,
        model => _,
        messages => _,
        prompt => _,
        max_tokens => _,
        temperature => _,
        top_p => _,
        stream => _,
        tee => _,
        tools => _,
        _ => _
    },
    map()
) -> {ok, _} | {error, _}.
completions(Base, Req, Opts) ->
    %% The deployed SGLang server exposes the OpenAI chat endpoint. The
    %% receipt and Explorer routes both use this shape; keeping the backend
    %% path explicit also survives nested AO-Core v1 dispatch where the
    %% public `chat-mode` marker is not retained in the inner message.
    Path = <<"/v1/chat/completions">>,
    do_inference_request(Base, Req, Opts, Path).

%% @doc Handle chat completion requests.
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

%% @doc Handle models request.
-spec models(
    #{ 'inference-opts' => _, _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ status := 200, 'content-type' := binary(), body := binary() }}.
models(Base, _Req, Opts) ->
    Model = hb_ao:get(<<"inference-opts/model_name">>, Base,
        hb_ao:get(<<"inference-opts/model_name">>, Opts,
            <<"google/gemma-4-26B-A4B-it">>, Opts), Opts),
    Body = hb_json:encode(#{
        <<"object">> => <<"list">>,
        <<"data">> => [#{
            <<"id">> => Model,
            <<"object">> => <<"model">>,
            <<"owned_by">> => <<"google">>,
            <<"root">> => Model,
            <<"max_model_len">> => 32768
        }]
    }),
    {ok, #{
        <<"status">> => 200,
        <<"content-type">> => <<"application/json">>,
        <<"body">> => Body
    }}.

%% @doc Handle v1 API requests.
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

%% @doc Check the health of the inference server.
-spec health(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, _} | {error, _}.
health(_Base, _Req, Opts) ->
    forward_health_check(Opts).


%% Internal functions

forward_health_check(Opts) ->
    Peer = iolist_to_binary(["http://localhost:", ?SERVER_PORT]),
    
    case hb_http_client:request(
        #{
            method => <<"GET">>,
            peer => Peer,
            path => <<"/health">>,
            headers => #{},
            body => <<>>
        },
        Opts
    ) of
        {ok, Status, _Headers, Body} when Status >= 200 andalso Status < 300 ->
            {ok, #{
                <<"status">> => <<"healthy">>,
                <<"body">> => Body,
                <<"timestamp">> => os:system_time(millisecond)
            }};
        {ok, Status, _Headers, Body} ->
            {error, #{
                <<"status">> => Status,
                <<"message">> => <<"Backend unhealthy">>,
                <<"body">> => Body
            }};
        {error, Details} ->
            {error, #{
                <<"status">> => 503,
                <<"message">> => hb_util:bin(Details)
            }}
    end.

do_inference_request(Base, Req, Opts, Path) ->
    %% HTTP/device callers can carry backend routing in the resolved base or
    %% request map. Promote those keys into the options consumed by relay@1.0
    %% while preserving the existing defaults when they are absent.
    RequestOpts = merge_request_opts(Base, Req, Opts),
    Params = extract_inference_params(Req, RequestOpts),
    IsStream = case maps:get(<<"stream">>, Params, false) of
        true -> true;
        <<"true">> -> true;
        _ -> false
    end,
    case IsStream of
        true ->
            Body = hb_json:encode(Params),
            #{
                <<"stream_generator">> => fun(Sender) -> 
                    stream_from_backend(Sender, <<"POST">>, Path, Body, RequestOpts)
                end
            };
        false ->
            Body = prepare_request_body(Req, RequestOpts),
            Response = relay_to_backend(<<"POST">>, Path, Body, RequestOpts),
            
            case should_include_attestation(Req, RequestOpts) of
                true -> add_attestation(Response, Base, Req, Body, RequestOpts);
                false -> format_response(Response, Req, RequestOpts)
            end
    end.

merge_request_opts(Base, Req, Opts) ->
    lists:foldl(
        fun(Key, Acc) ->
            case first_defined([
                maps:get(Key, Req, undefined),
                maps:get(Key, Base, undefined),
                maps:get(Key, Opts, undefined)
            ]) of
                undefined -> Acc;
                Value -> Acc#{Key => Value}
            end
        end,
        Opts,
        [<<"agent-api-peer">>, <<"agent-api-path">>, <<"agent-api-key">>]
    ).

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value.

prepare_request_body(Req, Opts) ->
    case hb_ao:get(<<"body">>, Req, not_found, Opts) of
        not_found -> hb_json:encode(extract_inference_params(Req, Opts));
        Body when is_binary(Body) -> Body;
        Body when is_map(Body) -> hb_json:encode(Body)
    end.

should_include_attestation(Req, Opts) ->
    case hb_ao:get(<<"tee">>, Req, false, Opts) of
        <<"true">> -> true;
        true -> true;
        _ -> false
    end.

extract_inference_params(Req, Opts) ->
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
%% backend payload. The HTTP message that reached HyperBEAM also carries
%% transport fields (`cf-connecting-ip', `x-forwarded-for', `x-real-ip',
%% `user-agent', cookies, credentials) and the private peer `ip'; none of
%% them is hashed into the nonce or published.
public_request(Req, Body, Opts) ->
    Params = try hb_json:decode(Body) of
        Decoded when is_map(Decoded) -> maps:with(?PUBLIC_PARAM_KEYS, Decoded);
        _ -> #{}
    catch _:_ -> #{}
    end,
    case hb_ao:get(<<"tee">>, Req, not_found, Opts) of
        not_found -> Params;
        Tee -> Params#{<<"tee">> => Tee}
    end.

relay_to_backend(Method, DefaultPath, Body, Opts) ->
    Peer = maps:get(<<"agent-api-peer">>, Opts,
        iolist_to_binary(["http://localhost:", ?SERVER_PORT])),
    Path = maps:get(<<"agent-api-path">>, Opts, DefaultPath),
    Payload0 = #{
        <<"path">>         => Path,
        <<"method">>       => Method,
        <<"body">>         => Body,
        <<"content-type">> => <<"application/json">>
    },
    Payload = case maps:get(<<"agent-api-key">>, Opts, undefined) of
        undefined -> Payload0;
        ApiKey    -> Payload0#{<<"authorization">> => <<"Bearer ", ApiKey/binary>>}
    end,
    hb_ao:resolve(
        #{<<"device">>       => <<"relay@1.0">>,
          <<"content-type">> => <<"application/json">>,
          <<"peer">>         => Peer},
        #{<<"path">>   => <<"call">>,
          <<"target">> => <<"payload">>,
          <<"payload">> => Payload},
        Opts#{hashpath => ignore, cache_control => [<<"no-store">>, <<"no-cache">>]}
    ).

format_response({ok, Res}, Req, Opts) ->
    Body = hb_ao:get(<<"body">>, Res, Opts),
    ?event(push, {format_response, Req, hb_ao:get(<<"type">>, Req)}),
    %% Check if this is being called for scheduling (aos Send with resolve)
    %% vs direct HTTP call. dev_push:maybe_evaluate_message sets force_message => true
    case hb_ao:get(<<"type">>, Req) of
        <<"Message">> ->
            %% For scheduling: return only valid AO message fields (ANS-104 compatible)
            {ok, #{
                <<"data">> => Body,
                <<"action">> => <<"Inference-Response">>
            }};
        _ ->
            %% For direct HTTP: return full HTTP response format
            {ok, #{
                <<"status">> => hb_ao:get(<<"status">>, Res, 200, Opts),
                <<"content-type">> => hb_ao:get(<<"content-type">>, Res, <<"application/json">>, Opts),
                <<"body">> => Body
            }}
    end;
format_response({error, Error}, Req, _Opts) ->
    case hb_ao:get(<<"type">>, Req) of
        <<"Message">> ->
            %% For scheduling: return AO message format
            {error, #{
                <<"data">> => error_body(Error),
                <<"action">> => <<"Inference-Error">>
            }};
        _ ->
            %% For direct HTTP: return HTTP error format
            {error, #{
                <<"status">> => 500,
                <<"message">> => <<"Request failed">>,
                <<"body">> => error_body(Error)
            }}
    end.

error_body(Error) when is_map(Error) -> hb_json:encode(Error);
error_body(Error) -> hb_util:bin(Error).

add_attestation({ok, Res}, Base, Req, Body, Opts) ->
    %% `raw' is published verbatim, and the NVIDIA report binds its SHA-256.
    %% Record only the public generation request, never the HTTP message.
    MergedData = #{
        <<"request">> => public_request(Req, Body, Opts),
        <<"response">> => hb_private:reset(Res),
        <<"ao-core">> => ao_core_evidence(Base, Req, Res, Opts),
        <<"timestamp">> => os:system_time(millisecond),
        <<"nonce">> => hb_util:to_hex(crypto:strong_rand_bytes(32))
    },
    NonceHex = hb_util:to_hex(hb_crypto:sha256(hb_json:encode(MergedData))),
    
    %% Generate attestation - result contains evidences, claims, eat, verified
    AttestationResult = case dev_sev_gpu:generate(#{}, #{nonce => NonceHex}, Opts) of
        {ok, ResultJSON} -> 
            case hb_json:decode(ResultJSON) of
                Map when is_map(Map) -> Map;
                _ -> #{}
            end;
        _ -> #{}
    end,
    
    %% Merge attestation result with raw and nonce at same level
    AttestationData = maps:merge(AttestationResult, #{
        <<"raw">> => hb_json:encode(MergedData),
        <<"nonce">> => NonceHex
    }),
    
    ResponseBody = hb_ao:get(<<"body">>, Res, Opts),
    DecodedBody = hb_json:decode(ResponseBody),
    EnhancedBody = hb_json:encode(DecodedBody#{
        <<"attestation">> => AttestationData,
        <<"resolved_model">> => hb_opts:get(inference_opts, #{}, Opts)
    }),
    
    %% Check context: scheduling (aos) vs direct HTTP
    case hb_ao:get(<<"type">>, Req) of
        <<"Message">> ->
            %% For scheduling: return only valid AO message fields (ANS-104 compatible)
            {ok, #{
                <<"data">> => EnhancedBody,
                <<"action">> => <<"Inference-Response">>
            }};
        _ ->
            %% For direct HTTP: return full HTTP response format
            {ok, #{
                <<"status">> => hb_ao:get(<<"status">>, Res, 200, Opts),
                <<"content-type">> => <<"application/json">>,
                <<"body">> => EnhancedBody
            }}
    end;
add_attestation({error, Error}, _Base, Req, _Body, Opts) ->
    format_response({error, Error}, Req, Opts).

%% @doc Preserve the AO-Core execution link in the public attestation envelope.
%% Stage 9 will place the same hashpath in the response private message; this
%% copy makes it available to an HTTP receipt verifier without exposing `priv'.
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

stream_from_backend(Sender, Method, Path, Body, _Opts) ->
    {ok, ConnPid} = gun:open("localhost", list_to_integer(?SERVER_PORT)),
    {ok, _Protocol} = gun:await_up(ConnPid),
    StreamRef = gun:request(ConnPid, Method, Path, [{<<"content-type">>, <<"application/json">>}], Body),
    receive_stream(ConnPid, StreamRef, Sender).

receive_stream(ConnPid, StreamRef, Sender) ->
    receive
        {gun_response, ConnPid, StreamRef, nofin, _Status, _Headers} ->
            receive_stream(ConnPid, StreamRef, Sender);
        {gun_response, ConnPid, StreamRef, fin, _Status, _Headers} ->
            ok;
        {gun_data, ConnPid, StreamRef, nofin, Data} ->
            Sender(Data),
            receive_stream(ConnPid, StreamRef, Sender);
        {gun_data, ConnPid, StreamRef, fin, Data} ->
            Sender(Data);
        {gun_error, ConnPid, StreamRef, Reason} ->
            ?event(inference, {stream_error, Reason}),
            ok;
        {gun_down, ConnPid, _Protocol, _Reason, _KilledStreams} ->
             ok;
        Other ->
            ?event(inference, {unexpected_stream_msg, Other}),
            receive_stream(ConnPid, StreamRef, Sender)
    after 30000 ->
        ok
    end.

-ifdef(TEST).

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

request_opts_promote_backend_route_test() ->
    Result = merge_request_opts(
        #{<<"agent-api-peer">> => <<"https://example.test">>},
        #{<<"agent-api-path">> => <<"/v1/chat/completions">>},
        #{}
    ),
    ?assertEqual(<<"https://example.test">>,
        maps:get(<<"agent-api-peer">>, Result)),
    ?assertEqual(<<"/v1/chat/completions">>,
        maps:get(<<"agent-api-path">>, Result)).

public_request_keeps_only_generation_inputs_test() ->
    Req = leaky_request(),
    Public = public_request(Req, prepare_request_body(Req, #{}), #{}),
    ?assertEqual(
        lists:sort([<<"model">>, <<"messages">>, <<"max_tokens">>, <<"tee">>]),
        lists:sort(maps:keys(Public))),
    assert_no_transport_leak(Public).

attestation_raw_excludes_transport_fields_test() ->
    Req = leaky_request(),
    Body = prepare_request_body(Req, #{}),
    Res = #{<<"status">> => 200, <<"content-type">> => <<"application/json">>,
        <<"body">> => <<"{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}">>},
    {ok, #{<<"body">> := Enhanced} = Result} = add_attestation(
        {ok, Res}, #{<<"device">> => <<"inference@1.0">>}, Req, Body, #{}),
    assert_no_transport_leak(Result),
    #{<<"attestation">> := #{<<"raw">> := Raw, <<"nonce">> := Nonce}} =
        hb_json:decode(Enhanced),
    %% The NVIDIA report is requested for this nonce; it must still be the
    %% digest of the published `raw' bytes.
    ?assertEqual(Nonce, hb_util:to_hex(hb_crypto:sha256(Raw))),
    ?assertMatch(#{<<"request">> := #{<<"messages">> :=
            [#{<<"content">> := <<"hi">>}]}},
        hb_json:decode(Raw)).

-endif.
