%%% @doc Receipt decorator for the existing OpenAI-compatible inference device.
%%%
%%% The decorator commits the original request/response transcript to the node
%%% observation and includes the receipt in the public response JSON. Publishing
%%% waits for the signed Arweave bundle to be posted and its chunks seeded.
-module(dev_inference_receipt).
-implements(<<"inference_receipt@1.0">>).
-specification("docs/spec/inference_receipt.md").
-export([info/1, completions/3, chat/3, models/3, health/3, v1/3,
    verify_hashpath/3, publish/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).
-define(INFERENCE_BASE, #{<<"device">> => <<"inference@1.0">>}).

%% Request keys that may enter the executed and published AO-Core request:
%% the generation parameters `inference@1.0' relays (minus the `user'
%% identifier, see its `PUBLIC_PARAM_KEYS'), the attestation flag and the
%% caller's execution-profile declarations.
-define(EXECUTION_KEYS, [
    <<"model">>, <<"prompt">>, <<"messages">>, <<"max_tokens">>,
    <<"temperature">>, <<"top_p">>, <<"n">>, <<"stream">>,
    <<"stop">>, <<"presence_penalty">>, <<"frequency_penalty">>,
    <<"logit_bias">>, <<"seed">>, <<"top_k">>,
    <<"repetition_penalty">>, <<"length_penalty">>, <<"early_stopping">>,
    <<"tools">>, <<"tool_choice">>,
    <<"tee">>, <<"type">>,
    <<"model-sha256">>, <<"runtime-build-hash">>, <<"inference-profile">>,
    <<"model-source">>, <<"model-tx">>, <<"workload-manifest-id">>,
    <<"model-revision">>, <<"runtime-name">>, <<"runtime-version">>
]).

%% @doc Return the public device description.
info(_Opts) ->
    #{
        exports => [<<"completions">>, <<"chat">>, <<"models">>,
            <<"health">>, <<"v1">>, <<"verify-hashpath">>, <<"publish">>],
        description => <<"Inference transcript receipt decorator">>,
        version => ?VERSION
    }.

%% @doc Decorate a non-streaming completion response with a receipt.
-spec completions(
    #{ _ => _ },
    #{
        body => _,
        model => _,
        messages => _,
        stream => _,
        'model-sha256' => _,
        'model-source' => _,
        'model-tx' => _,
        'runtime-build-hash' => _,
        'inference-profile' => _,
        'workload-manifest-id' => _,
        'measurement-mode' => _,
        'gpu-inventory-root' => _,
        _ => _
    },
    map()
) -> {ok, _} | {error, _}.
completions(Base, Req, Opts) ->
    %% The inference completion handler targets `/v1/chat/completions`.
    %% Resolve one AO-Core step so its exact input can accompany the receipt.
    decorate(<<"completions">>, Base, Req, Opts).

%% @doc Preserve the chat route so `/chat/completions` reaches completions/3.
-spec chat(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ _ => _ }}.
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
-spec models(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, _} | {error, _}.
models(Base, Req, Opts) -> delegate(<<"models">>, Base, Req, Opts).

%% @doc Delegate health checks without creating a workload receipt.
-spec health(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, _} | {error, _}.
health(Base, Req, Opts) -> delegate(<<"health">>, Base, Req, Opts).

%% @doc Preserve the OpenAI v1 route so nested `/chat/completions` dispatch
%% reaches this decorator's chat export instead of attaching a receipt to the
%% intermediate route envelope.
-spec v1(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ _ => _ }}.
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
-spec publish(
    #{ _ => _ },
    #{ receipt => _, body => _, _ => _ },
    map()
) -> {ok, #{ status := 200, id := binary(), _ => _ }} | {error, _}.
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
    PublishOpts = publish_opts(Opts),
    %% The ANS-104 commitment device returns the signed structured message
    %% expected by `bundler@1.0`; no second conversion is necessary.
    Signed = hb_message:commit(Unsigned, PublishOpts, <<"ans104@1.0">>),
    case hb_ao:resolve(
        #{<<"device">> => <<"bundler@1.0">>},
        Signed#{<<"path">> => <<"item">>, <<"await">> => true},
        PublishOpts
    ) of
        {ok, #{<<"id">> := ID, <<"bundle-id">> := BundleID,
                <<"bundle-status">> := <<"complete">>} = Response} ->
            %% Keep the item ID at the response top level. AO-Core may expose
            %% the nested body through a cache link during HTTP encoding, so
            %% callers must not need to dereference that link just to index
            %% the Arweave data item.
            {ok, #{<<"status">> => 200, <<"id">> => ID,
                <<"bundle-id">> => BundleID,
                <<"bundle-status">> => <<"complete">>,
                <<"body">> => Response}};
        {ok, _Response} ->
            {error, #{<<"status">> => 502, <<"body">> => #{
                <<"error">> => <<"receipt-publish-incomplete">>
            }}};
        {error, Reason} ->
            {error, #{<<"status">> => 502, <<"body">> => #{
                <<"error">> => <<"receipt-publish-failed">>,
                <<"reason">> => json_safe(Reason)
            }}}
    end.

%% Only node configuration selects the publication wallet. Keep the node's
%% identity key separate from its funded upload wallet, and key this bundler
%% worker by the latter so an existing unfunded worker cannot be reused.
publish_opts(Opts) ->
    Base = Opts#{hashpath => ignore, <<"bundler-max-items">> => 1},
    case hb_opts:get(<<"receipt-wallet-location">>, undefined, Opts) of
        undefined -> Base;
        Path ->
            Wallet = hb:wallet(hb_util:list(Path)),
            (maps:without([<<"http-server">>, http_server,
                <<"priv-wallet">>, priv_wallet], Base))#{
                <<"priv-wallet">> => Wallet}
    end.

%% @doc Recompute AO-Core HashPath from the recorded message transcript and
%% compare it with the HashPath the receipt recorded.
%%
%% The receipt stores the exact base, request, and response messages under
%% `ao-core.verification-input', and the HashPath AO-Core assigned to the
%% response under `ao-core.hashpath'. The response's own copy is private
%% (`priv.hashpath'); HyperBEAM drops private keys from HTTP requests, so it
%% survives only in `verification-input-term'. Every recorded value that is
%% present must equal the HashPath recomputed from the base and request.
-spec verify_hashpath(
    #{ _ => _ },
    #{
        'ao-core' => _,
        receipt => _,
        'verification-input' => _,
        'verification-input-term' => _,
        _ => _
    },
    map()
) -> {ok, #{ status := 200 | 422, body := _ }}.
verify_hashpath(_Base, Req, Opts) ->
    %% Callers can post the receipt's `ao-core' object, the whole receipt,
    %% or the verification keys directly. JSON may also arrive under `body'.
    Roots = [Root || Root <- [Req, get_map(<<"body">>, Req, Opts)],
        is_map(Root)],
    Sections = [Section ||
        Root <- Roots,
        Section <- [get_map(<<"ao-core">>, Root, Opts),
            get_map(<<"ao-core">>, get_map(<<"receipt">>, Root, Opts), Opts)],
        is_map(Section)],
    Input = load_transcript(
        find_evidence(<<"verification-input">>, Roots ++ Sections, Opts), Opts),
    TermInput =
        find_evidence(<<"verification-input-term">>, Roots ++ Sections, Opts),
    case verification_messages(TermInput, Input, Opts) of
        {ok, Base, Request, Response, Rest} ->
            try
                Recomputed = hb_path:hashpath(Base, Request, Opts),
                Recorded = recorded_hashpaths(Sections, Response, Opts),
                ChainVerified = Rest == [] orelse
                    hb_path:verify_hashpath([Request, Response | Rest], Opts),
                {ok, #{<<"status">> => 200, <<"body">> =>
                    hashpath_result(Recomputed, Recorded, ChainVerified)}}
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

%% The JSON codec stores the nested transcript messages of an HTTP request as
%% lazy cache links; load them so the messages can be hashed. Links recorded
%% inside the transcript itself are JSON objects until restore_json_links/1.
load_transcript(Input, Opts) when is_map(Input) ->
    try hb_cache:ensure_all_loaded(Input, Opts)
    catch _:_ -> Input
    end;
load_transcript(Input, _Opts) -> Input.

%% The HashPath values the receipt recorded for the response, with their
%% source. `ao-core.hashpath' is public; the response's private copy is only
%% present when the transcript arrives as an Erlang term.
recorded_hashpaths(Sections, Response, Opts) ->
    Public = find_evidence(<<"hashpath">>, Sections, Opts),
    Private = maps:get(<<"hashpath">>, hb_private:from_message(Response),
        undefined),
    [{Source, Hashpath} ||
        {Source, Hashpath} <- [{<<"ao-core.hashpath">>, Public},
            {<<"response.priv.hashpath">>, Private}],
        is_binary(Hashpath)].

%% A receipt with no recorded HashPath (`ao-core.status=not-captured') has
%% nothing to compare against, so it is reported as unverified rather than
%% compared with an unrelated value such as the response ID.
hashpath_result(Recomputed, [], _ChainVerified) ->
    #{
        <<"verified">> => false,
        <<"reason">> => <<"hashpath-not-captured">>,
        <<"recomputed-hashpath">> => Recomputed
    };
hashpath_result(Recomputed, [{_, Expected} | _] = Recorded, ChainVerified) ->
    Matches = lists:all(fun({_, Hashpath}) -> Hashpath =:= Recomputed end,
        Recorded),
    Result = #{
        <<"verified">> => Matches andalso ChainVerified,
        <<"expected-hashpath">> => Expected,
        <<"hashpath-sources">> => [Source || {Source, _} <- Recorded],
        <<"recomputed-hashpath">> => Recomputed
    },
    case {Matches, ChainVerified} of
        {true, true} -> Result;
        {false, _} -> Result#{<<"reason">> => <<"hashpath-mismatch">>};
        {true, false} -> Result#{<<"reason">> => <<"hashpath-chain-mismatch">>}
    end.

%% Read posted evidence as plain data. hb_ao:get/4 would dispatch to any
%% `device' key inside a posted receipt (e.g. a TEE report's device path).
get_map(Key, Msg, Opts) ->
    case evidence_value(Key, Msg, Opts) of
        Value when is_map(Value) -> Value;
        _ -> undefined
    end.

find_evidence(Key, Scopes, Opts) ->
    first_defined([evidence_value(Key, Scope, Opts) || Scope <- Scopes]).

evidence_value(Key, Msg, Opts) when is_map(Msg) ->
    try hb_maps:get(Key, Msg, undefined, Opts) of
        null -> undefined;
        Value -> Value
    catch _:_ -> undefined
    end;
evidence_value(_Key, _Msg, _Opts) -> undefined.

restore_json_links(#{<<"type">> := <<"link">>, <<"id">> := ID} = Map) ->
    {link, ID, maps:get(<<"metadata">>, Map, #{})};
restore_json_links(Map) when is_map(Map) ->
    maps:map(fun(_Key, Value) -> restore_json_links(Value) end, Map);
restore_json_links(List) when is_list(List) ->
    [restore_json_links(Value) || Value <- List];
restore_json_links(Value) -> Value.

%% @doc Resolve the base inference device using ordinary AO-Core dispatch.
delegate(Path, Base, Req, Opts) ->
    hb_ao:resolve(
        #{<<"device">> => <<"inference@1.0">>},
        %% Preserve `tee` so the delegated inference device can attach its
        %% hardware evidence to the same response that carries the receipt.
        maps:put(<<"path">>, Path, Req),
        delegate_opts(Base, Req, Opts)
    ).

delegate_opts(Base, Req, Opts) ->
    lists:foldl(
        fun(Key, Acc) ->
            case first_defined([maps:get(Key, Req, undefined),
                    maps:get(Key, Base, undefined)]) of
                undefined -> Acc;
                Value -> Acc#{Key => Value}
            end
        end,
        Opts,
        [<<"agent-api-peer">>, <<"agent-api-path">>, <<"agent-api-key">>]
    ).

%% @doc Build the single AO-Core request that is executed and recorded.
%%
%% The inbound HTTP message also carries transport fields (`cf-connecting-ip',
%% `x-forwarded-for', `x-real-ip', `user-agent', cookies, credentials) and
%% HyperBEAM's private peer `ip'. A HashPath commits to every key of the
%% executed request, so the allowlist is applied before execution: the
%% published transcript remains verifiable without carrying caller metadata.
execution_request(Path, Req, Opts) ->
    BodyParams = case hb_ao:get(<<"body">>, Req, undefined, Opts) of
        Bin when is_binary(Bin) ->
            try hb_json:decode(Bin) of
                Map when is_map(Map) -> maps:with(?EXECUTION_KEYS, Map);
                _ -> #{}
            catch _:_ -> #{}
            end;
        Map when is_map(Map) -> maps:with(?EXECUTION_KEYS, Map);
        _ -> #{}
    end,
    Params = lists:foldl(
        fun(Key, Acc) ->
            case hb_ao:get(Key, Req, not_found, Opts) of
                not_found -> Acc;
                Value -> Acc#{Key => Value}
            end
        end,
        BodyParams,
        ?EXECUTION_KEYS
    ),
    (hb_cache:ensure_all_loaded(Params, Opts))#{
        <<"path">> => Path,
        %% Identical prompts must not share a HashPath or a cached result,
        %% which would carry an earlier request's GPU attestation.
        <<"request-nonce">> => hb_util:encode(crypto:strong_rand_bytes(32))
    }.

%% The receipt is the record of this step's HashPath, so generate it even
%% when the node skips HashPaths globally (`hashpath: ignore'), and never
%% answer the attested step from the result cache.
execution_opts(Base, Req, Opts) ->
    (delegate_opts(Base, Req, Opts))#{
        <<"hashpath">> => update,
        <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
    }.

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
            ExecutionReq = execution_request(Path, Req, Opts),
            case hb_ao:resolve(?INFERENCE_BASE, ExecutionReq,
                    execution_opts(Base, Req, Opts)) of
                {ok, Response} ->
                    add_receipt(Response, Req, ExecutionReq, Opts);
                {error, _} = Error -> Error;
                Other -> {ok, Other}
            end
    end.

%% @doc Attach the receipt after committing the original response body/data.
add_receipt(Response, Req, ExecutionReq, Opts) when is_map(Response) ->
    Body = first_defined([
        hb_ao:get(<<"body">>, Response, undefined, Opts),
        hb_ao:get(<<"data">>, Response, <<>>, Opts)
    ]),
    Receipt = make_receipt(Req, ExecutionReq, Body, Response, Opts),
    %% HTTP response encoding serializes the `body` field and can omit
    %% sibling AO-Core keys. Put the receipt in the JSON body as well so the
    %% public API and the Arweave uploader carry the exact same evidence.
    BodyWithReceipt = body_with_receipt(Body, Receipt, Opts),
    {ok, maps:without([<<"body+link">>, <<"data+link">>], Response#{
        <<"body">> => BodyWithReceipt,
        <<"data">> => BodyWithReceipt,
        <<"receipt">> => Receipt
    })};
add_receipt(Response, _Req, _ExecutionReq, _Opts) ->
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

%% @doc Build and commit a request/response observation. Request-derived
%% fields come from the executed public request; `Req' only selects how the
%% node probes its own inventory and measurement.
make_receipt(Req, ExecutionReq, Body, Response, Opts) ->
    RequestDigest = digest(ExecutionReq),
    Inventory = resolve_inventory(Req, Opts),
    Measurement = resolve_measurement(Req, RequestDigest, Opts),
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
        <<"model">> => maps:get(<<"model">>, ExecutionReq, undefined),
        <<"workload-manifest-id">> =>
            maps:get(<<"workload-manifest-id">>, ExecutionReq, undefined),
        <<"gpu-inventory-digest">> => InventoryDigest,
        <<"gpu-inventory">> => Inventory,
        <<"measurement-id">> => MeasurementID,
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"sequence">> => erlang:system_time(millisecond),
        <<"provenance-class">> => Provenance
    },
    Receipt0 = add_execution_bindings(ReceiptBase, ExecutionReq, Opts, Inventory),
    ReceiptMeasurement = Receipt0#{
        <<"system-measurement">> => Measurement
    },
    Receipt1 = ReceiptMeasurement#{
        <<"ao-core">> =>
            ao_core_evidence(?INFERENCE_BASE, ExecutionReq, Response, Opts),
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
        <<"verification-status">> =>
            hashpath_verification(Base, Req, Hashpath, Opts)
    }.

%% Compare against the captured HashPath, as verify-hashpath does. The
%% response's private copy may be absent when the value came from the
%% inference device's public evidence.
hashpath_verification(_Base, _Req, undefined, _Opts) -> <<"not-captured">>;
hashpath_verification(Base, Req, Hashpath, Opts) ->
    case catch hb_path:hashpath(Base, Req, Opts) of
        Hashpath -> <<"verified">>;
        Other when is_binary(Other) -> <<"failed">>;
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

%% @doc Resolve the composed measurement bound to this request digest.
resolve_measurement(Req, RequestDigest, Opts) ->
    case hb_ao:resolve(
        #{<<"device">> => <<"inference_measurement@1.0">>},
        #{<<"path">> => <<"fresh">>,
          <<"nonce">> => RequestDigest,
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

execution_request_is_allowlisted_and_fresh_test() ->
    A = execution_request(<<"completions">>, leaky_request(), #{}),
    B = execution_request(<<"completions">>, leaky_request(), #{}),
    assert_no_transport_leak(A),
    ?assertEqual(<<"completions">>, maps:get(<<"path">>, A)),
    ?assertNotEqual(maps:get(<<"request-nonce">>, A),
        maps:get(<<"request-nonce">>, B)),
    ?assertEqual(maps:remove(<<"request-nonce">>, A),
        maps:remove(<<"request-nonce">>, B)).

receipt_excludes_transport_fields_and_verifies_test_() ->
    {timeout, 60, fun() ->
        Chat = hb_json:encode(#{<<"object">> => <<"chat.completion">>,
            <<"choices">> => [#{<<"index">> => 0, <<"finish_reason">> => <<"stop">>,
                <<"message">> => #{<<"role">> => <<"assistant">>,
                    <<"content">> => <<"ok">>}}]}),
        {ok, URL, Handle} = hb_mock_server:start(
            [{"/v1/chat/completions", chat, {200, Chat}}]),
        try
            Opts = #{<<"agent-api-peer">> => URL,
                %% Mirrors the production node, which disables HashPaths.
                <<"hashpath">> => ignore,
                <<"priv-wallet">> => ar_wallet:new(),
                <<"store">> => hb_test_utils:test_store()},
            {ok, Result} = completions(#{}, leaky_request(), Opts),
            assert_no_transport_leak(Result),
            #{<<"ao-core">> := AOCore, <<"request-digest">> := RequestDigest} =
                maps:get(<<"receipt">>, Result),
            Term = maps:get(<<"verification-input-term">>, AOCore),
            Transcript = binary_to_term(hb_util:decode(Term), [safe]),
            assert_no_transport_leak(Transcript),
            %% Verifiers can recompute the request digest from the transcript.
            ?assertEqual(RequestDigest, digest(maps:get(request, Transcript))),
            ?assertEqual(<<"verified">>,
                maps:get(<<"verification-status">>, AOCore)),
            {ok, #{<<"body">> := Verification}} = verify_hashpath(#{},
                #{<<"verification-input-term">> => Term}, Opts),
            ?assertEqual(true, maps:get(<<"verified">>, Verification))
        after
            hb_mock_server:stop(Handle)
        end
    end}.
publish_posts_signed_bundle_before_returning_test_() ->
    {timeout, 20, fun() ->
        Parent = self(),
        {Server, NodeOpts} = hb_mock_server:start_arweave_gateway(#{
            price => {200, <<"12345">>},
            tx_anchor => {200, hb_util:encode(crypto:strong_rand_bytes(32))},
            chunk => fun(_Req) ->
                Parent ! {chunk_started, self()},
                receive release_chunk -> {200, <<"OK">>} end
            end
        }),
        try
            Opts = NodeOpts#{<<"priv-wallet">> => ar_wallet:new(),
                <<"store">> => hb_test_utils:test_store()},
            spawn_link(fun() ->
                Parent ! {published, publish(#{},
                    #{<<"receipt">> => #{<<"test">> => <<"receipt">>}}, Opts)}
            end),
            Handler = receive {chunk_started, PID} -> PID
                after 10000 -> error(no_signed_bundle_submitted) end,
            receive {published, _} -> error(returned_before_seeding)
                after 50 -> ok end,
            Handler ! release_chunk,
            receive {published, Result} ->
                ?assertMatch({ok, #{<<"id">> := _, <<"bundle-id">> := _,
                    <<"bundle-status">> := <<"complete">>}}, Result)
                after 3000 -> error(no_publish_completion) end
        after
            hb_mock_server:stop(Server)
        end
    end}.

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

%% Transcript recorded on the H100 guest on 2026-10-12 by HyperBEAM
%% feat/self-docs-v011 @ 28baa3d2 (`ao-core.status=captured').
-define(CAPTURED_HASHPATH, <<"QdzzDp_izRHiWSt3D3zBQcgym1XnDtQJJ9W8DuaWOHo/"
    "hDjPRer0jfXtHMDhJIRBozzWusYX6-sed0_5HEH2NFk">>).

captured_transcript() ->
    #{
        <<"base">> => #{<<"device">> => <<"inference@1.0">>},
        <<"request">> => #{
            <<"accept">> => <<"*/*">>,
            <<"accept-bundle">> => false,
            <<"content-type">> => <<"application/json">>,
            <<"host">> => <<"127.0.0.1">>,
            <<"max_tokens">> => 8,
            <<"messages">> => [#{
                <<"content">> => <<"Reply with the single word: pong">>,
                <<"role">> => <<"user">>
            }],
            <<"method">> => <<"POST">>,
            <<"model">> => <<"google/gemma-4-26B-A4B-it">>,
            <<"path">> => <<"completions">>,
            <<"priv">> => #{<<"ip">> => <<"127.0.0.1">>},
            <<"temperature">> => 0,
            <<"user-agent">> => <<"curl/8.5.0">>
        },
        <<"response">> => #{
            <<"body">> => <<"{\"id\":\"8e78675fae60435ea0f3c88182e3eec0\","
                "\"object\":\"chat.completion\",\"created\":1791805877,"
                "\"model\":\"google/gemma-4-26B-A4B-it\",\"choices\":[{"
                "\"index\":0,\"message\":{\"role\":\"assistant\","
                "\"content\":\"pong\",\"reasoning_content\":null,"
                "\"tool_calls\":null},\"logprobs\":null,"
                "\"finish_reason\":\"stop\",\"matched_stop\":106}],"
                "\"usage\":{\"prompt_tokens\":20,\"total_tokens\":22,"
                "\"completion_tokens\":2,\"prompt_tokens_details\":null,"
                "\"reasoning_tokens\":0},\"metadata\":{"
                "\"weight_version\":\"default\"}}">>,
            <<"content-type">> => <<"application/json">>,
            <<"priv">> => #{<<"hashpath">> => ?CAPTURED_HASHPATH},
            <<"status">> => 200
        }
    }.

%% Encode a request the way an HTTP client sends it: JSON through the
%% `json@1.0' codec, with private keys removed on ingress.
http_request(Msg) ->
    hb_private:reset(hb_message:convert(hb_json:encode(json_safe(Msg)),
        <<"structured@1.0">>, <<"json@1.0">>, #{})).

verify_http(Msg) ->
    {ok, #{<<"status">> := 200, <<"body">> := Result}} =
        verify_hashpath(#{}, http_request(Msg), #{}),
    Result.

verify_hashpath_accepts_captured_receipt_test() ->
    AOCore = #{
        <<"status">> => <<"captured">>,
        <<"hashpath">> => ?CAPTURED_HASHPATH,
        <<"verification-input">> => captured_transcript()
    },
    Result = verify_http(#{<<"ao-core">> => AOCore}),
    ?assertEqual(true, maps:get(<<"verified">>, Result)),
    ?assertEqual(?CAPTURED_HASHPATH, maps:get(<<"expected-hashpath">>, Result)),
    ?assertEqual(?CAPTURED_HASHPATH,
        maps:get(<<"recomputed-hashpath">>, Result)),
    ?assertEqual([<<"ao-core.hashpath">>],
        maps:get(<<"hashpath-sources">>, Result)),
    %% The whole receipt can be posted as well.
    ?assertEqual(true, maps:get(<<"verified">>,
        verify_http(#{<<"receipt">> => #{<<"ao-core">> => AOCore}}))),
    %% A changed request no longer reproduces the recorded HashPath.
    #{<<"request">> := Request} = Transcript = captured_transcript(),
    Tampered = verify_http(#{<<"ao-core">> => AOCore#{
        <<"verification-input">> => Transcript#{
            <<"request">> => Request#{<<"max_tokens">> => 9}}}}),
    ?assertEqual(false, maps:get(<<"verified">>, Tampered)),
    ?assertEqual(<<"hashpath-mismatch">>, maps:get(<<"reason">>, Tampered)),
    %% The response's private HashPath does not survive HTTP, so the
    %% transcript alone carries nothing to compare with.
    Bare = verify_http(#{<<"verification-input">> => captured_transcript()}),
    ?assertEqual(false, maps:get(<<"verified">>, Bare)),
    ?assertEqual(<<"hashpath-not-captured">>, maps:get(<<"reason">>, Bare)).

verify_hashpath_checks_every_recorded_copy_test() ->
    #{<<"base">> := Base, <<"request">> := Request,
        <<"response">> := Response} = captured_transcript(),
    Term = hb_util:encode(term_to_binary(
        #{base => Base, request => Request, response => Response})),
    Verify = fun(Hashpath) ->
        {ok, #{<<"body">> := Result}} = verify_hashpath(#{}, #{
            <<"ao-core">> => #{
                <<"hashpath">> => Hashpath,
                <<"verification-input-term">> => Term
            }
        }, #{}),
        Result
    end,
    Agreeing = Verify(?CAPTURED_HASHPATH),
    ?assertEqual(true, maps:get(<<"verified">>, Agreeing)),
    ?assertEqual([<<"ao-core.hashpath">>, <<"response.priv.hashpath">>],
        maps:get(<<"hashpath-sources">>, Agreeing)),
    Conflicting = Verify(<<"QdzzDp_izRHiWSt3D3zBQcgym1XnDtQJJ9W8DuaWOHo/other">>),
    ?assertEqual(false, maps:get(<<"verified">>, Conflicting)),
    ?assertEqual(<<"hashpath-mismatch">>, maps:get(<<"reason">>, Conflicting)).

%% Receipts from HyperBEAM 2c03978a recorded no HashPath.
verify_hashpath_reports_not_captured_receipt_test() ->
    #{<<"response">> := Response} = Transcript = captured_transcript(),
    Result = verify_http(#{<<"ao-core">> => #{
        <<"status">> => <<"not-captured">>,
        <<"verification-input">> => Transcript#{
            <<"response">> => maps:remove(<<"priv">>, Response)}
    }}),
    ?assertEqual(false, maps:get(<<"verified">>, Result)),
    ?assertEqual(<<"hashpath-not-captured">>, maps:get(<<"reason">>, Result)),
    ?assertEqual(?CAPTURED_HASHPATH,
        maps:get(<<"recomputed-hashpath">>, Result)),
    ?assertNot(maps:is_key(<<"expected-hashpath">>, Result)).

%% The receipt's own verification-status uses the same comparison, including
%% when the HashPath comes from the inference device's public evidence.
receipt_verification_status_uses_captured_hashpath_test() ->
    #{<<"base">> := Base, <<"request">> := Request} = captured_transcript(),
    Response = fun(Evidence) ->
        #{<<"status">> => 200, <<"body">> =>
            hb_json:encode(#{<<"ao-core">> => Evidence})}
    end,
    Captured = ao_core_evidence(Base, Request,
        Response(#{<<"hashpath">> => ?CAPTURED_HASHPATH}), #{}),
    ?assertEqual(<<"captured">>, maps:get(<<"status">>, Captured)),
    ?assertEqual(<<"verified">>, maps:get(<<"verification-status">>, Captured)),
    ?assertEqual(true, maps:get(<<"verified">>, verify_http(
        #{<<"ao-core">> => maps:without([<<"verification-input-term">>],
            Captured)}))),
    NotCaptured = ao_core_evidence(Base, Request, Response(#{}), #{}),
    ?assertEqual(<<"not-captured">>, maps:get(<<"status">>, NotCaptured)),
    ?assertEqual(<<"not-captured">>,
        maps:get(<<"verification-status">>, NotCaptured)).

-endif.
