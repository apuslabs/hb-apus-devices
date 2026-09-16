%%% @doc Receipt decorator for the existing OpenAI-compatible inference device.
%%%
%%% The decorator leaves response bytes untouched and returns a sibling receipt
%%% that commits the request/response transcript to the node observation.
-module(dev_inference_receipt).
-implements(<<"inference_receipt@1.0">>).
-export([info/1, completions/3, chat/3, models/3, health/3, v1/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).

%% @doc Return the public device description.
info(_Opts) ->
    #{
        exports => [<<"completions">>, <<"chat">>, <<"models">>,
            <<"health">>, <<"v1">>],
        description => <<"Inference transcript receipt decorator">>,
        version => ?VERSION
    }.

%% @doc Decorate a non-streaming completion response with a receipt.
completions(Base, Req, Opts) ->
    decorate(<<"completions">>, Base, Req, Opts).

%% @doc Preserve the chat route so `/chat/completions` reaches completions/3.
chat(Base, Req, Opts) ->
    {ok, hb_util:deep_merge(
        Base,
        Req#{
            <<"device">> => <<"inference_receipt@1.0">>,
            <<"chat-mode">> => true
        },
        Opts
    )}.

%% @doc Delegate model discovery without creating a workload receipt.
models(Base, Req, Opts) -> delegate(<<"models">>, Base, Req, Opts).

%% @doc Delegate health checks without creating a workload receipt.
health(Base, Req, Opts) -> delegate(<<"health">>, Base, Req, Opts).

%% @doc Preserve the OpenAI v1 route so nested `/chat/completions` dispatch
%% reaches this decorator's chat export instead of attaching a receipt to the
%% intermediate route envelope.
v1(Base, Req, Opts) ->
    {ok, hb_util:deep_merge(
        Base,
        Req#{<<"device">> => <<"inference_receipt@1.0">>},
        Opts
    )}.

%% @doc Resolve the base inference device using ordinary AO-Core dispatch.
delegate(Path, Base, Req, Opts) ->
    DelegateOpts = lists:foldl(
        fun(Key, Acc) ->
            case first_defined([maps:get(Key, Req, undefined),
                    maps:get(Key, Base, undefined)]) of
                undefined -> Acc;
                Value -> Acc#{Key => Value}
            end
        end,
        Opts,
        [<<"agent-api-peer">>, <<"agent-api-path">>, <<"agent-api-key">>]
    ),
    hb_ao:resolve(
        #{<<"device">> => <<"inference@1.0">>},
        maps:put(<<"path">>, Path, maps:remove(<<"tee">>, Req)),
        DelegateOpts
    ).

%% @doc Reject streaming and decorate the complete response transcript.
decorate(Path, Base, Req, Opts) ->
    case truthy(hb_ao:get(<<"stream">>, Req, false, Opts)) of
        true ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => #{
                    <<"error">> => <<"receipt-streaming-unsupported">>,
                    <<"message">> =>
                        <<"receipt v1 requires a complete non-streaming response">>
                }
            }};
        false ->
            case delegate(Path, Base, Req, Opts) of
                {ok, Response} ->
                    add_receipt(Response, Req, Opts);
                {error, _} = Error -> Error;
                Other -> {ok, Other}
            end
    end.

%% @doc Attach a sibling receipt while preserving response body/data bytes.
add_receipt(Response, Req, Opts) when is_map(Response) ->
    Body = first_defined([
        hb_ao:get(<<"body">>, Response, undefined, Opts),
        hb_ao:get(<<"data">>, Response, <<>>, Opts)
    ]),
    Receipt = make_receipt(Req, Body, Opts),
    {ok, Response#{<<"receipt">> => Receipt}};
add_receipt(Response, _Req, _Opts) ->
    {ok, Response}.

%% @doc Build and commit a request/response observation.
make_receipt(Req, Body, Opts) ->
    Inventory = resolve_inventory(Req, Opts),
    Measurement = resolve_measurement(Req, Opts),
    RequestDigest = digest(hb_private:reset(Req)),
    ResponseDigest = digest(Body),
    InventoryDigest = maps:get(<<"inventory-digest">>, Inventory, undefined),
    MeasurementID = maps:get(<<"measurement-id">>, Measurement, undefined),
    Provenance = maps:get(<<"provenance-class">>, Measurement,
        <<"receipt-observed">>),
    Receipt0 = #{
        <<"type">> => <<"apus-inference-receipt">>,
        <<"version">> => ?VERSION,
        <<"request-id">> => hb_util:encode(crypto:strong_rand_bytes(16)),
        <<"request-digest">> => RequestDigest,
        <<"response-digest">> => ResponseDigest,
        <<"model">> => hb_ao:get(<<"model">>, Req, undefined, Opts),
        <<"workload-manifest-id">> =>
            hb_ao:get(<<"workload-manifest-id">>, Req, undefined, Opts),
        <<"gpu-inventory-digest">> => InventoryDigest,
        <<"measurement-id">> => MeasurementID,
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"sequence">> => erlang:system_time(millisecond),
        <<"provenance-class">> => Provenance
    },
    Committed = try hb_message:commit(Receipt0, Opts)
    catch _:_ -> Receipt0
    end,
    Receipt0#{
        <<"receipt-id">> => hb_message:id(Committed, signed, Opts),
        <<"signed-receipt">> => Committed
    }.

%% @doc Resolve the stable inventory needed by the receipt.
resolve_inventory(Req, Opts) ->
    case hb_ao:resolve(
        #{<<"device">> => <<"gpu_inventory@1.0">>},
        #{<<"path">> => <<"report">>,
          <<"gpu-inventory-root">> =>
              hb_ao:get(<<"gpu-inventory-root">>, Req, <<"/sys">>, Opts)},
        Opts
    ) of
        {ok, Response} -> hb_ao:get(<<"body">>, Response, #{}, Opts);
        _ -> #{}
    end.

%% @doc Resolve the composed measurement used for this transcript.
resolve_measurement(Req, Opts) ->
    case hb_ao:resolve(
        #{<<"device">> => <<"inference_measurement@1.0">>},
        #{<<"path">> => <<"boot">>,
          <<"measurement-mode">> =>
              hb_ao:get(<<"measurement-mode">>, Req, <<"auto">>, Opts),
          <<"gpu-inventory-root">> =>
              hb_ao:get(<<"gpu-inventory-root">>, Req, <<"/sys">>, Opts)},
        Opts
    ) of
        {ok, Response} -> measurement_fields(hb_ao:get(<<"body">>, Response, #{}, Opts), Opts);
        _ -> #{}
    end.

%% @doc Extract measurement metadata without asserting a trust class.
measurement_fields(Body, Opts) when is_map(Body) ->
    Composition = hb_ao:get(<<"apus-gpu-composition">>, Body, #{}, Opts),
    #{
        <<"measurement-id">> => hb_message:id(Body, signed, Opts),
        <<"provenance-class">> => maps:get(
            <<"provenance-class">>, Composition, <<"receipt-observed">>)
    };
measurement_fields(_Body, _Opts) -> #{}.

%% @doc Hash AO-Core values after canonical JSON encoding.
digest(Value) when is_binary(Value) ->
    hb_util:encode(crypto:hash(sha256, Value));
digest(Value) ->
    hb_util:encode(crypto:hash(sha256, hb_json:encode(Value))).

%% @doc Interpret the common boolean encodings accepted by AO requests.
truthy(true) -> true;
truthy(<<"true">>) -> true;
truthy(<<"1">>) -> true;
truthy(1) -> true;
truthy(_) -> false.

%% @doc Return the first non-undefined value.
first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value.

-ifdef(TEST).

request_digest_changes_with_body_test() ->
    ?assertNotEqual(digest(#{<<"x">> => 1}), digest(#{<<"x">> => 2})).

streaming_is_truthy_test() ->
    ?assertEqual(true, truthy(<<"true">>)).

v1_route_keeps_receipt_device_test() ->
    {ok, Result} = v1(#{}, #{}, #{}),
    ?assertEqual(<<"inference_receipt@1.0">>,
        maps:get(<<"device">>, Result)).

-endif.
