%%% @doc Receipt decorator for the existing OpenAI-compatible inference device.
%%%
%%% The decorator commits the original request/response transcript to the node
%%% observation and includes the receipt in the public response JSON.
-module(dev_inference_receipt).
-implements(<<"inference_receipt@1.0">>).
-export([info/1, completions/3, chat/3, models/3, health/3, v1/3,
    verify_hashpath/3, publish/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).

%% @doc Return the public device description.
info(_Opts) ->
    #{
        exports => [<<"completions">>, <<"chat">>, <<"models">>,
            <<"health">>, <<"v1">>, <<"verify-hashpath">>, <<"publish">>],
        description => <<"Inference transcript receipt decorator">>,
        version => ?VERSION
    }.

%% @doc Decorate a non-streaming completion response with a receipt.
completions(Base, Req, Opts) ->
    %% The Explorer's public receipt endpoint is chat-completions. Route the
    %% nested AO-Core request explicitly through the chat handler so the
    %% llama.cpp backend receives `/v1/chat/completions`.
    decorate(<<"v1/chat/completions">>, Base, Req, Opts).

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
        Req#{<<"device">> => <<"inference_receipt@1.0">>,
            %% The public v1 receipt route is the chat-completions route
            %% used by the Explorer. Preserve that semantic when delegating
            %% through AO-Core's nested v1 path.
            <<"chat-mode">> => true},
        Opts
    )}.

%% @doc Publish a completed receipt through HyperBEAM's internal bundler.
%% The receipt device owns the upload boundary; callers only receive the
%% bundler result and never handle a wallet or Arweave signature.
publish(_Base, Req, Opts) ->
    Receipt = first_defined([
        hb_ao:get(<<"receipt">>, Req, undefined, Opts),
        hb_ao:get(<<"body">>, Req, undefined, Opts),
        Req
    ]),
    Data = case Receipt of
        Bin when is_binary(Bin) -> Bin;
        Value -> hb_json:encode(Value)
    end,
    %% `bundler@1.0' accepts signed ANS-104 items. Sign and normalize the
    %% receipt inside this Device Forge device, then hand the structured item
    %% directly to the preloaded bundler implementation. This keeps wallet
    %% handling and Arweave transport inside HyperBEAM.
    Unsigned = #{<<"data">> => Data,
        <<"content-type">> => <<"application/json">>},
    PublishOpts = Opts#{hashpath => ignore},
    %% The ANS-104 commitment device returns the signed structured message
    %% expected by `bundler@1.0`; no second conversion is necessary.
    Signed = hb_message:commit(Unsigned, PublishOpts, <<"ans104@1.0">>),
    case hb_ao:resolve(
        #{<<"device">> => <<"bundler@1.0">>},
        Signed#{<<"path">> => <<"item">>},
        PublishOpts
    ) of
        {ok, Response} ->
            %% Keep the item ID at the response top level. AO-Core may expose
            %% the nested body through a cache link during HTTP encoding, so
            %% callers must not need to dereference that link just to index
            %% the Arweave data item.
            ID = case Response of
                Map when is_map(Map) -> maps:get(<<"id">>, Map, undefined);
                _ -> undefined
            end,
            {ok, #{<<"status">> => 200, <<"id">> => ID,
                <<"body">> => Response}};
        {error, Reason} ->
            {error, #{<<"status">> => 502, <<"body">> => #{
                <<"error">> => <<"receipt-publish-failed">>,
                <<"reason">> => json_safe(Reason)
            }}}
    end.

%% @doc Recompute AO-Core HashPath from the recorded message transcript.
%%
%% The receipt stores the exact base, request, and response messages under
%% `ao-core.verification-input'. This endpoint deliberately calls the same
%% hb_path verifier used by the resolver instead of trusting the recorded
%% verification-status field.
verify_hashpath(_Base, Req, Opts) ->
    Input = first_defined([
        hb_ao:get(<<"verification-input">>, Req, undefined, Opts),
        hb_ao:get(<<"verification-input">>,
            hb_ao:get(<<"body">>, Req, #{}, Opts), undefined, Opts),
        hb_ao:get(<<"ao-core">>, Req, undefined, Opts)
    ]),
    TermInput = first_defined([
        hb_ao:get(<<"verification-input-term">>, Req, undefined, Opts),
        hb_ao:get(<<"verification-input-term">>,
            hb_ao:get(<<"body">>, Req, #{}, Opts), undefined, Opts)
    ]),
    case verification_messages(TermInput, Input, Opts) of
        {ok, Base, Request, Response, Rest} ->
            try
                Verified = hb_path:verify_hashpath(
                    [Base, Request, Response | Rest], Opts),
                {ok, #{<<"status">> => 200, <<"body">> => #{
                    <<"verified">> => Verified,
                    <<"expected-hashpath">> =>
                        hb_path:from_message(hashpath, Response, Opts),
                    <<"recomputed-hashpath">> =>
                        hb_path:hashpath(Base, Request, Opts)
                }}}
            catch _:_ ->
                {ok, #{<<"status">> => 422, <<"body">> => #{
                    <<"verified">> => false,
                    <<"error">> => <<"invalid-hashpath-transcript">>
                }}}
            end;
        {error, Reason} ->
            {ok, #{<<"status">> => 422, <<"body">> => #{
                <<"verified">> => false,
                <<"error">> => <<"hashpath-verification-input-missing">>,
                <<"reason">> => json_safe(Reason)
            }}}
    end.

verification_messages(Term, _Input, _Opts) when is_binary(Term) ->
    try
        #{base := Base, request := Request, response := Response} =
            binary_to_term(hb_util:decode(Term), [safe]),
        {ok, Base, Request, Response, []}
    catch _:_ -> {error, <<"recorded AO-Core term could not be decoded">>}
    end;
verification_messages(_Term, #{<<"base">> := Base,
                        <<"request">> := Request,
                        <<"response">> := Response} = Input, _Opts) ->
    Rest = maps:get(<<"rest">>, Input, []),
    {ok, restore_json_links(Base), restore_json_links(Request),
        restore_json_links(Response), restore_json_links(Rest)};
verification_messages(_, _, _Opts) ->
    {error, <<"receipt does not contain recorded AO-Core messages">>}.

restore_json_links(#{<<"type">> := <<"link">>, <<"id">> := ID} = Map) ->
    {link, ID, maps:get(<<"metadata">>, Map, #{})};
restore_json_links(Map) when is_map(Map) ->
    maps:map(fun(_Key, Value) -> restore_json_links(Value) end, Map);
restore_json_links(List) when is_list(List) ->
    [restore_json_links(Value) || Value <- List];
restore_json_links(Value) -> Value.

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
        %% Preserve `tee` so the delegated inference device can attach its
        %% hardware evidence to the same response that carries the receipt.
        maps:put(<<"path">>, Path, Req),
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
                    add_receipt(Response, Req, Opts, Base);
                {error, _} = Error -> Error;
                Other -> {ok, Other}
            end
    end.

%% @doc Attach the receipt after committing the original response body/data.
add_receipt(Response, Req, Opts, Base) when is_map(Response) ->
    Body = first_defined([
        hb_ao:get(<<"body">>, Response, undefined, Opts),
        hb_ao:get(<<"data">>, Response, <<>>, Opts)
    ]),
    Receipt = make_receipt(Req, Body, Response, Opts, Base),
    %% HTTP response encoding serializes the `body` field and can omit
    %% sibling AO-Core keys. Put the receipt in the JSON body as well so the
    %% public API and the Arweave uploader carry the exact same evidence.
    BodyWithReceipt = body_with_receipt(Body, Receipt, Opts),
    {ok, maps:without([<<"body+link">>, <<"data+link">>], Response#{
        <<"body">> => BodyWithReceipt,
        <<"data">> => BodyWithReceipt,
        <<"receipt">> => Receipt
    })};
add_receipt(Response, _Req, _Opts, _Base) ->
    {ok, Response}.

body_with_receipt(Body, Receipt, _Opts) when is_binary(Body) ->
    try
        Decoded = hb_json:decode(Body),
        hb_json:encode(Decoded#{<<"receipt">> => json_safe(Receipt)})
    catch
        _:_ -> hb_json:encode(#{<<"response">> => Body, <<"receipt">> => json_safe(Receipt)})
    end;
body_with_receipt(Body, Receipt, _Opts) when is_map(Body) ->
    Body#{<<"receipt">> => json_safe(Receipt)};
body_with_receipt(Body, _Receipt, _Opts) ->
    Body.

json_safe(Map) when is_map(Map) ->
    maps:fold(
        fun(_Key, undefined, Acc) -> Acc;
           (Key, Value, Acc) -> Acc#{Key => json_safe(Value)}
        end,
        #{},
        Map
    );
json_safe(List) when is_list(List) -> [json_safe(Value) || Value <- List];
json_safe({link, ID, Meta}) -> #
    {<<"id">> => ID, <<"type">> => <<"link">>, <<"metadata">> => json_safe(Meta)};
json_safe(Tuple) when is_tuple(Tuple) ->
    hb_util:bin(Tuple);
json_safe(Value) -> Value.

%% @doc Build and commit a request/response observation.
make_receipt(Req, Body, Response, Opts, Base) ->
    Inventory = resolve_inventory(Req, Opts),
    Measurement = resolve_measurement(Req, Opts),
    RequestDigest = digest(hb_private:reset(Req)),
    ResponseDigest = digest(Body),
    InventoryDigest = maps:get(<<"inventory-digest">>, Inventory, undefined),
    MeasurementID = maps:get(<<"measurement-id">>, Measurement, undefined),
    Provenance = maps:get(<<"provenance-class">>, Measurement,
        <<"receipt-observed">>),
    ReceiptBase = #{
        <<"type">> => <<"apus-inference-receipt">>,
        <<"version">> => ?VERSION,
        <<"request-id">> => hb_util:encode(crypto:strong_rand_bytes(16)),
        <<"request-digest">> => RequestDigest,
        <<"response-digest">> => ResponseDigest,
        <<"model">> => hb_ao:get(<<"model">>, Req, undefined, Opts),
        <<"workload-manifest-id">> =>
            hb_ao:get(<<"workload-manifest-id">>, Req, undefined, Opts),
        <<"gpu-inventory-digest">> => InventoryDigest,
        <<"gpu-inventory">> => Inventory,
        <<"measurement-id">> => MeasurementID,
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"sequence">> => erlang:system_time(millisecond),
        <<"provenance-class">> => Provenance
    },
    Receipt0 = add_execution_bindings(ReceiptBase, Req, Opts, Inventory),
    ReceiptMeasurement = Receipt0#{
        <<"system-measurement">> => Measurement
    },
    Receipt1 = ReceiptMeasurement#{
        <<"ao-core">> => ao_core_evidence(Base, Req, Response, Opts),
        <<"device-chain">> => device_chain_evidence(Opts)
    },
    Committed = try hb_message:commit(Receipt1, Opts)
    catch _:_ -> Receipt1
    end,
    Receipt1#{
        <<"receipt-id">> => hb_message:id(Committed, signed, Opts),
        <<"signed-receipt">> => Committed
    }.

%% @doc Expose AO-Core's execution link in terms a verifier can explain.
%% The hashpath is read from the resolved response private message; it is not
%% re-hashed by this device or by the Explorer uploader.
ao_core_evidence(Base, Req, Response, Opts) ->
    Priv = hb_private:from_message(Response),
    PublicEvidence = public_ao_core_evidence(Response, Opts),
    Hashpath = first_defined([
        maps:get(<<"hashpath">>, Priv, undefined),
        maps:get(<<"hashpath">>, PublicEvidence, undefined)
    ]),
    #{
        <<"status">> => case Hashpath of
            undefined -> <<"not-captured">>;
            _ -> <<"captured">>
        end,
        <<"source">> => case maps:get(<<"source">>, PublicEvidence, undefined) of
            undefined -> <<"HyperBEAM AO-Core resolve stage 9">>;
            Source -> Source
        end,
        <<"hashpath">> => Hashpath,
        <<"hashpath-algorithm">> => hashpath_algorithm(Req, Response, Opts),
        <<"request-id">> => safe_message_id(Req, none, Opts),
        <<"response-id">> => safe_message_id(Response, none, Opts),
        <<"commitment-device">> => commitment_device(Response, Opts),
        <<"signers">> => safe_signers(Response, Opts),
        <<"verification-input">> => #{
            <<"base">> => Base,
            <<"request">> => Req,
            <<"response">> => Response
        },
        %% JSON is the public transport representation. Keep an opaque
        %% Erlang-term snapshot as well so Verify can restore AO-Core private
        %% metadata and run the exact HyperBEAM verifier after upload.
        <<"verification-input-term">> => hb_util:encode(term_to_binary(
            #{base => Base, request => Req, response => Response},
            [compressed])),
        <<"verification-status">> => hashpath_verification(Base, Req, Response, Opts)
    }.

hashpath_verification(Base, Req, Response, Opts) ->
    case catch hb_path:verify_hashpath([Base, Req, Response], Opts) of
        true -> <<"verified">>;
        false -> <<"failed">>;
        _ -> <<"unavailable">>
    end.

%% The inference device exposes the AO-Core link in its JSON response because
%% the outer receipt decorator runs before AO-Core attaches private metadata.
%% Prefer that device-produced field over deriving a local digest here.
public_ao_core_evidence(Response, Opts) ->
    Body = hb_ao:get(<<"body">>, Response, undefined, Opts),
    Json = case Body of
        Bin when is_binary(Bin) ->
            try hb_json:decode(Bin) catch _:_ -> #{} end;
        Map when is_map(Map) -> Map;
        _ -> #{}
    end,
    case maps:get(<<"ao-core">>, Json, undefined) of
        Evidence when is_map(Evidence) -> Evidence;
        _ ->
            case maps:get(<<"attestation">>, Json, undefined) of
                #{<<"raw">> := Raw} when is_binary(Raw) ->
                    try
                        RawMap = hb_json:decode(Raw),
                        maps:get(<<"ao-core">>, RawMap, #{})
                    catch _:_ -> #{} end;
                _ -> #{}
            end
    end.

hashpath_algorithm(Req, Response, _Opts) ->
    case first_defined([
        maps:get(<<"hashpath-alg">>, Req, undefined),
        maps:get(<<"hashpath-alg">>, Response, undefined)
    ]) of
        undefined -> <<"sha-256-chain (AO-Core default)">>;
        Value -> Value
    end.

commitment_device(Response, Opts) ->
    case catch hb_message:commitment_devices(Response, Opts) of
        [Device | _] -> Device;
        _ -> undefined
    end.

safe_signers(Response, Opts) ->
    case catch hb_message:signers(Response, Opts) of
        Signers when is_list(Signers) -> Signers;
        _ -> []
    end.

safe_message_id(Message, Committers, Opts) ->
    case catch hb_message:id(hb_private:reset(Message), Committers, Opts) of
        ID when is_binary(ID) -> ID;
        _ -> undefined
    end.

%% @doc Record which Forge devices produced the receipt and measurement.
device_chain_evidence(Opts) ->
    #{
        <<"status">> => <<"captured">>,
        <<"receipt-device">> => <<"inference_receipt@1.0">>,
        <<"measurement-device">> => <<"inference_measurement@1.0">>,
        <<"inventory-device">> => <<"gpu_inventory@1.0">>,
        <<"loader">> => <<"HyperBEAM Device Forge preloaded-store">>,
        <<"implementation-id">> => maps:get(<<"device-implementation-id">>, Opts, undefined)
    }.

%% Include the execution profile facts in the signed receipt when configured.
%% These fields are bindings for independent verification; their absence keeps
%% older deployments readable and is reported as measurement-only by clients.
add_execution_bindings(Receipt, Req, Opts, Inventory) ->
    Candidates = [
        {<<"model-sha256">>, [maps:get(<<"model-sha256">>, Req, undefined),
            maps:get(<<"model-sha256">>, Opts, undefined),
            maps:get(<<"model_sha256">>, Inventory, undefined)]},
        {<<"runtime-build-hash">>, [maps:get(<<"runtime-build-hash">>, Req, undefined),
            maps:get(<<"runtime-build-hash">>, Opts, undefined),
            maps:get(<<"runtime_build_hash">>, Inventory, undefined)]},
        {<<"inference-profile">>, [maps:get(<<"inference-profile">>, Req, undefined),
            maps:get(<<"inference-profile">>, Opts, undefined),
            maps:get(<<"profile">>, Inventory, undefined)]},
        {<<"model-source">>, [maps:get(<<"model-source">>, Req, undefined),
            maps:get(<<"model-source">>, Opts, undefined)]},
        {<<"model-tx">>, [maps:get(<<"model-tx">>, Req, undefined),
            maps:get(<<"model-tx">>, Opts, undefined)]}
    ],
    lists:foldl(
        fun({Key, Values}, Acc) ->
            case first_defined(Values) of
                undefined -> Acc;
                Value -> Acc#{Key => Value}
            end
        end,
        Receipt,
        Candidates
    ).

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
        #{<<"path">> => <<"fresh">>,
          <<"nonce">> => digest(hb_private:reset(Req)),
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
    Integrated = maps:get(<<"measurement-integration">>, Composition, false),
    Evidence = materialize_link(hb_ao:get(<<"evidence">>, Body, #{}, Opts), Opts),
    Subject0 = materialize_link(hb_ao:get(<<"body">>, Body, #{}, Opts), Opts),
    Subject = case is_map(Subject0) of true -> Subject0; false -> #{} end,
    CpuTee = materialize_link(first_defined([
        maps:get(<<"cpu-tee">>, Body, undefined), Evidence]), Opts),
    GpuTee = materialize_link(hb_ao:get(<<"gpu-tee">>, Body, #{}, Opts), Opts),
    #{
        <<"measurement-id">> => hb_message:id(Body, signed, Opts),
        <<"status">> => case Integrated of true -> <<"measured">>; false -> <<"observed">> end,
        <<"measurement-device">> => <<"inference_measurement@1.0">>,
        <<"base-measurement-device">> => case Integrated of
            true -> <<"measurement@1.0">>;
            false -> undefined
        end,
        <<"measurement-integration">> => Integrated,
        <<"cpu-tee">> => CpuTee,
        <<"gpu-tee">> => GpuTee,
        <<"measurement-protocol">> => case Integrated of
            true -> <<"~measurement@1.0">>;
            false -> <<"inference_measurement@1.0 observation-only">>
        end,
        <<"provenance-class">> => maps:get(
            <<"provenance-class">>, Composition, <<"host-observed">>),
        <<"measurement-envelope">> => case maps:get(<<"type">>, Body, undefined) of
            <<"lapee-measurement">> -> <<"lapee-measurement">>;
            _ -> <<"apus-system-measurement">>
        end,
        <<"subject-id">> => maps:get(<<"subject-id">>, Composition, undefined),
        <<"nonce-binding">> => maps:get(<<"nonce-binding">>, Composition, undefined),
        <<"envelope">> => materialize_link(maps:without(
            [<<"cpu-tee">>, <<"gpu-tee">>, <<"apus-gpu-composition">>], Body), Opts),
        <<"system">> => maps:get(<<"system">>, Subject, undefined),
        <<"node">> => maps:get(<<"node">>, Subject, undefined),
        <<"evidence">> => Evidence
    };
measurement_fields(_Body, _Opts) -> #{}.

%% Nested evidence values are links in the signed AO message. Resolve the
%% small CPU TEE envelope before placing it in the public receipt so clients
%% can distinguish an available SNP device from a missing report.
materialize_link({link, _ID, _Meta} = Link, Opts) ->
    try materialize_link(hb_cache:ensure_loaded(Link, Opts), Opts)
    catch _:_ -> Link
    end;
materialize_link(Map, Opts) when is_map(Map) ->
    maps:map(fun(_Key, Value) -> materialize_link(Value, Opts) end, Map);
materialize_link(List, Opts) when is_list(List) ->
    [materialize_link(Value, Opts) || Value <- List];
materialize_link(Value, _Opts) -> Value.

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

verify_hashpath_checks_base_and_request_test() ->
    Base = #{<<"body">> => <<"original base">>},
    Request = #{<<"path">> => <<"echo">>, <<"body">> => <<"request">>},
    Response = #{<<"body">> => <<"response">>,
        <<"priv">> => #{<<"hashpath">> => hb_path:hashpath(Base, Request, #{})}},
    Verify = fun(B, R) ->
        Term = hb_util:encode(term_to_binary(
            #{base => B, request => R, response => Response})),
        {ok, #{<<"body">> := Result}} = verify_hashpath(#{},
            #{<<"verification-input-term">> => Term}, #{}),
        maps:get(<<"verified">>, Result)
    end,
    ?assertEqual(true, Verify(Base, Request)),
    ?assertEqual(false, Verify(Base#{<<"body">> => <<"changed base">>}, Request)),
    ?assertEqual(false, Verify(Base, Request#{<<"body">> => <<"changed request">>})).

verify_hashpath_rejects_invalid_transcript_test() ->
    Term = hb_util:encode(term_to_binary(
        #{base => 123, request => #{}, response => #{}})),
    {ok, #{<<"status">> := Status, <<"body">> := Result}} = verify_hashpath(#{},
        #{<<"verification-input-term">> => Term}, #{}),
    ?assertEqual(422, Status),
    ?assertEqual(false, maps:get(<<"verified">>, Result)).

-endif.
