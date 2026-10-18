%%% @doc `inference_receipt@1.0': a receipt decorator for `inference@1.0'.
%%%
%%% `completions' executes one allowlisted, non-streaming request on
%%% `inference@1.0' as an AO-Core step whose HashPath is always generated,
%%% then returns the runtime's JSON with a `receipt' added. The receipt binds
%%% digests of the executed request and the response, the step's AO-Core
%%% transcript and HashPath, the node's GPU inventory and a fresh
%%% measurement, and is signed with the node's identity.
%%%
%%% `verify-hashpath' recomputes a recorded transcript's HashPath, and
%%% `publish' signs a document carrying a receipt that names this node as an
%%% ANS-104 data item and submits it to the node's bundler.
-module(dev_inference_receipt).
-implements(<<"inference_receipt@1.0">>).
-specification("docs/spec/inference_receipt.md").
-export([info/1, completions/3, chat/3, v1/3, models/3, health/3,
    verify_hashpath/3, publish/3]).
-include_lib("hb/include/hb.hrl").

-define(VERSION, <<"1.0">>).
-define(RECEIPT_TYPE, <<"apus-inference-receipt">>).
-define(INFERENCE_BASE, #{<<"device">> => <<"inference@1.0">>}).
-define(JSON, <<"application/json">>).

%% The AO-Core stage whose function computes the recorded HashPath.
-define(HASHPATH_SOURCE,
    <<"HyperBEAM AO-Core stage 8 (cryptographic linking, hb_path:hashpath/3)">>).

%% Upper bound on the external term of a transcript (1 MiB), and on the
%% unpadded base64url text of `verification-input-term' (the encoded length
%% of 1 MiB, so its decoded bytes never exceed 1 MiB).
-define(MAX_TERM_BYTES, 1048576).
-define(MAX_TERM_TEXT_BYTES, 1398102).

%% Upper bound on a document submitted to `publish' (8 MiB).
-define(MAX_PUBLISH_BYTES, 8388608).

%% Keys a document submitted to `publish' must carry in its receipt, with
%% their JSON types.
-define(PUBLISH_REQUIRED_KEYS, [
    {<<"receipt-id">>, string}, {<<"request-digest">>, string},
    {<<"response-digest">>, string}, {<<"node-address">>, string},
    {<<"ao-core">>, object}, {<<"signed-receipt">>, object}
]).

%% Generation parameters `inference@1.0' relays to the runtime, without its
%% `user' caller identifier. Both specifications state this list.
-define(GENERATION_KEYS, [
    <<"model">>, <<"prompt">>, <<"messages">>, <<"max_tokens">>,
    <<"max_completion_tokens">>, <<"temperature">>, <<"top_p">>, <<"n">>,
    <<"stream">>, <<"stop">>, <<"presence_penalty">>,
    <<"frequency_penalty">>, <<"logit_bias">>, <<"seed">>, <<"top_k">>,
    <<"repetition_penalty">>, <<"length_penalty">>, <<"early_stopping">>,
    <<"tools">>, <<"tool_choice">>, <<"response_format">>,
    <<"chat_template_kwargs">>, <<"reasoning_effort">>
]).

%% Execution bindings: the operator's node option of each name, else the
%% executed request's declaration.
-define(BINDING_KEYS, [
    <<"model-sha256">>, <<"runtime-build-hash">>, <<"inference-profile">>,
    <<"model-source">>, <<"model-tx">>
]).

%% Execution-profile declarations a caller may record in the receipt.
-define(DECLARATION_KEYS, [
    <<"model-sha256">>, <<"runtime-build-hash">>, <<"inference-profile">>,
    <<"model-source">>, <<"model-tx">>, <<"workload-manifest-id">>,
    <<"model-revision">>, <<"runtime-name">>, <<"runtime-version">>
]).

%% Request keys that may enter the executed and published AO-Core request:
%% the generation parameters, the attestation flag, the response shape
%% selector and the caller's declarations.
-define(EXECUTION_KEYS,
    ?GENERATION_KEYS ++ [<<"tee">>, <<"type">>] ++ ?DECLARATION_KEYS).

%% @doc Return the public device description.
-spec info(map()) -> #{
    exports := [binary()],
    description := binary(),
    version := binary()
}.
info(_Opts) ->
    #{
        exports => [<<"completions">>, <<"chat">>, <<"v1">>, <<"models">>,
            <<"health">>, <<"verify-hashpath">>, <<"publish">>],
        description => <<"Signed receipts for inference@1.0 completions">>,
        version => ?VERSION
    }.

%% @doc Run a non-streaming completion and attach a receipt. A result of
%% `inference@1.0' that is not a message is returned unchanged.
-spec completions(
    #{ _ => _ },
    #{
        body => _,
        model => _,
        messages => _,
        stream => _,
        tee => _,
        'model-sha256' => _,
        'model-source' => _,
        'model-tx' => _,
        'runtime-build-hash' => _,
        'inference-profile' => _,
        'workload-manifest-id' => _,
        _ => _
    },
    map()
) -> {ok, _} | {error, _}.
completions(_Base, Req, Opts) ->
    decorate(<<"completions">>, Req, Opts).

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
            <<"device">> => <<"inference_receipt@1.0">>,
            <<"chat-mode">> => true
        },
        Opts
    )}.

%% @doc Return `inference@1.0/models' without creating a receipt.
-spec models(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, _} | {error, _}.
models(_Base, _Req, Opts) -> delegate(<<"models">>, Opts).

%% @doc Return `inference@1.0/health' without creating a receipt.
-spec health(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, _} | {error, _}.
health(_Base, _Req, Opts) -> delegate(<<"health">>, Opts).

%% @doc Route the OpenAI `/v1/...' prefix. The merged base message keeps this
%% device and `chat-mode: true', so `/v1/chat/completions' reaches
%% `completions' here rather than attaching a receipt to the route envelope.
-spec v1(
    #{ _ => _ },
    #{ _ => _ },
    map()
) -> {ok, #{ _ => _ }}.
v1(Base, Req, Opts) ->
    {ok, hb_util:deep_merge(
        Base,
        Req#{<<"device">> => <<"inference_receipt@1.0">>,
            <<"chat-mode">> => true},
        Opts
    )}.

%% @doc Publish a document carrying a receipt that names this node through
%% HyperBEAM's bundler. The device signs the ANS-104 item; callers never
%% handle a wallet or a signature. With the `receipt-publishers' node option
%% set, only requests signed by one of the listed addresses are accepted.
-spec publish(
    #{ _ => _ },
    #{ receipt => _, body => _, _ => _ },
    map()
) -> {ok, #{ id := binary(), 'bundle-id' := binary(), _ => _ }}
    | {error, #{ status := integer(), 'content-type' := binary(),
        body := binary() }}.
publish(_Base, Req, Opts) ->
    Value = first_defined([
        hb_ao:get(<<"receipt">>, Req, undefined, Opts),
        hb_ao:get(<<"body">>, Req, undefined, Opts)
    ]),
    case {authorized_publisher(Req, Opts), Value} of
        {false, _} ->
            error_reply(403, #{<<"error">> => <<"receipt-publisher-not-allowed">>});
        {true, undefined} ->
            error_reply(400, #{<<"error">> => <<"receipt-required">>});
        {true, _} ->
            case publishable_document(Value, Opts) of
                {ok, Data} -> publish_receipt(Data, Opts);
                {error, Status, Body} -> error_reply(Status, Body)
            end
    end.

%% @doc The bytes to publish: a binary as given, any other value as the JSON
%% encoding of its JSON form. The document must fit the size limit and carry
%% a receipt whose `node-address' is this node (publishable_receipt/2).
publishable_document(Value, Opts) ->
    Loaded = try hb_cache:ensure_all_loaded(Value, Opts)
    catch _:_ -> Value
    end,
    Encoded = case Loaded of
        Bin when is_binary(Bin) -> {ok, Bin};
        _ ->
            try {ok, hb_json:encode(json_safe(Loaded))}
            catch _:_ -> error
            end
    end,
    case Encoded of
        {ok, Data} when byte_size(Data) > ?MAX_PUBLISH_BYTES ->
            {error, 413, #{
                <<"error">> => <<"receipt-too-large">>,
                <<"limit">> => ?MAX_PUBLISH_BYTES
            }};
        {ok, Data} ->
            case publishable_receipt(Data, Opts) of
                ok -> {ok, Data};
                {error, node_mismatch} ->
                    {error, 422, #{<<"error">> => <<"receipt-node-mismatch">>}};
                {error, Reason} ->
                    {error, 422, #{
                        <<"error">> => <<"receipt-invalid">>,
                        <<"reason">> => Reason
                    }}
            end;
        error ->
            {error, 422, #{
                <<"error">> => <<"receipt-invalid">>,
                <<"reason">> => <<"not-a-json-object">>
            }}
    end.

%% @doc The document is a JSON object that is a receipt (`type' is
%% `apus-inference-receipt'), or that carries one under `report.receipt'.
%% The receipt must hold the required keys with their JSON types, and its
%% `node-address' must be this node's address. A publication record whose
%% receipt does not name the node is accepted when its `attestation' is the
%% one `inference@1.0' attaches with `tee=true': `nonce' is the SHA-256 of
%% `raw' and GPU evidence is present (bound_attestation/1). `signed-receipt' is not
%% verified here: a JSON round trip in another language can change committed
%% values (an integral float such as `1.0' becomes an integer, and integers
%% beyond 2^53 are rounded), so a signature check would refuse genuine
%% receipts.
publishable_receipt(Data, Opts) ->
    Document = try hb_json:decode(Data) catch _:_ -> undefined end,
    case Document of
        #{<<"type">> := ?RECEIPT_TYPE} ->
            receipt_requirements(Document, Opts);
        #{<<"report">> := #{<<"receipt">> := Receipt}} = Record
                when is_map(Receipt) ->
            case receipt_requirements(Receipt, Opts) of
                ok -> ok;
                Error ->
                    case bound_attestation(
                            maps:get(<<"attestation">>, Record, undefined)) of
                        true -> ok;
                        false -> Error
                    end
            end;
        Map when is_map(Map) ->
            {error, <<"receipt-not-found">>};
        _ ->
            {error, <<"not-a-json-object">>}
    end.

receipt_requirements(#{<<"type">> := ?RECEIPT_TYPE} = Receipt, Opts) ->
    Missing = [Key || {Key, Type} <- ?PUBLISH_REQUIRED_KEYS,
        not json_type(Type, maps:get(Key, Receipt, undefined))],
    case Missing of
        [Key | _] -> {error, <<"invalid-", Key/binary>>};
        [] ->
            case maps:get(<<"node-address">>, Receipt) =:= node_address(Opts) of
                true -> ok;
                false -> {error, node_mismatch}
            end
    end;
receipt_requirements(_Receipt, _Opts) ->
    {error, <<"invalid-type">>}.

%% @doc Whether an attestation is bound to its `raw' document: `nonce' is the
%% lowercase hex SHA-256 of `raw', as `inference@1.0' derives it, and the
%% attestation carries at least one evidence entry.
bound_attestation(#{<<"raw">> := Raw, <<"nonce">> := Nonce,
        <<"evidences">> := [_ | _]}) when is_binary(Raw), is_binary(Nonce) ->
    Nonce =:= binary:encode_hex(crypto:hash(sha256, Raw), lowercase);
bound_attestation(_) ->
    false.

json_type(string, Value) -> is_binary(Value) andalso Value =/= <<>>;
json_type(object, Value) -> is_map(Value).

%% The address of the node's identity wallet, which signs `signed-receipt'.
node_address(Opts) ->
    case hb_opts:get(priv_wallet, no_viable_wallet, Opts) of
        no_viable_wallet -> undefined;
        Wallet -> hb_util:human_id(ar_wallet:to_address(Wallet))
    end.

%% An error result that HyperBEAM serves as `Status' with a JSON body. A
%% `reason' that has no JSON encoding is left out.
error_reply(Status, Body) ->
    JSON = try hb_json:encode(json_safe(Body))
    catch _:_ -> hb_json:encode(json_safe(maps:remove(<<"reason">>, Body)))
    end,
    {error, #{
        <<"status">> => Status,
        <<"content-type">> => ?JSON,
        <<"body">> => JSON
    }}.

%% Without `receipt-publishers' any caller may publish. With it, a listed
%% address must have committed to the published key (`receipt', else `body'),
%% and its commitments must verify against the request as the device sees
%% it.
authorized_publisher(Req, Opts) ->
    case hb_opts:get(<<"receipt-publishers">>, undefined, Opts) of
        undefined -> true;
        Allowed when is_list(Allowed) ->
            Key = case hb_maps:is_key(<<"receipt">>, Req, Opts) of
                true -> <<"receipt">>;
                false -> <<"body">>
            end,
            lists:any(
                fun(Signer) ->
                    lists:member(Signer, Allowed) andalso
                        signed_by(Signer, Key, Req, Opts)
                end,
                safe_signers(Req, Opts)
            );
        _ -> false
    end.

signed_by(Signer, Key, Req, Opts) ->
    Committers = #{<<"committers">> => [Signer]},
    try
        lists:member(Key, hb_message:committed(Req, Committers, Opts))
            andalso hb_message:verify(Req, Committers, Opts) =:= true
    catch _:_ -> false
    end.

publish_receipt(Data, Opts) ->
    %% `bundler@1.0' accepts signed ANS-104 items: the ANS-104 commitment
    %% device returns the signed structured message it expects.
    Unsigned = #{<<"data">> => Data,
        <<"content-type">> => <<"application/json">>},
    PublishOpts = publish_opts(Opts),
    Signed = hb_message:commit(Unsigned, PublishOpts, <<"ans104@1.0">>),
    case hb_ao:resolve(
        #{<<"device">> => <<"bundler@1.0">>},
        Signed#{<<"path">> => <<"item">>, <<"await">> => true},
        PublishOpts
    ) of
        {ok, #{<<"id">> := ID, <<"bundle-id">> := BundleID,
                <<"bundle-status">> := <<"complete">>} = Response} ->
            %% The item ID stays at the top level: HTTP encoding may expose
            %% the nested body as a cache link, and callers index the data
            %% item without dereferencing it.
            {ok, #{<<"id">> => ID,
                <<"bundle-id">> => BundleID,
                <<"bundle-status">> => <<"complete">>,
                <<"body">> => Response}};
        {ok, _Response} ->
            error_reply(502, #{<<"error">> => <<"receipt-publish-incomplete">>});
        {_Status, Reason} ->
            error_reply(502, #{
                <<"error">> => <<"receipt-publish-failed">>,
                <<"reason">> => Reason
            })
    end.

%% Only node configuration selects the publication wallet. The node's
%% identity key stays separate from its funded upload wallet, and the bundler
%% worker is keyed by the latter so an unfunded worker is never reused.
publish_opts(Opts) ->
    Base = Opts#{<<"hashpath">> => ignore, <<"bundler-max-items">> => 1},
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
%%
%% `verification-input-term' is unauthenticated input. Its text is bounded to
%% the base64url length of 1 MiB, compressed terms are refused (their
%% uncompressed size is allocated before decoding), and the term is decoded
%% in safe mode and must contain only plain data.
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
) -> {ok, #{ status := 200, body := _ }}
    | {error, #{ status := 400 | 422, 'content-type' := binary(),
        body := binary() }}.
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
                error_reply(422, #{
                    <<"verified">> => false,
                    <<"error">> => <<"invalid-hashpath-transcript">>
                })
            end;
        {invalid_term, Reason} ->
            error_reply(400, #{
                <<"verified">> => false,
                <<"error">> => <<"invalid-verification-input-term">>,
                <<"reason">> => Reason
            });
        {error, Reason} ->
            error_reply(422, #{
                <<"verified">> => false,
                <<"error">> => <<"hashpath-verification-input-missing">>,
                <<"reason">> => Reason
            })
    end.

verification_messages(Term, _Input, _Opts) when is_binary(Term) ->
    case decode_transcript_term(Term) of
        {ok, #{base := Base, request := Request, response := Response}} ->
            {ok, Base, Request, Response, []};
        {error, Reason} -> {invalid_term, Reason}
    end;
verification_messages(_Term, #{<<"base">> := Base,
                        <<"request">> := Request,
                        <<"response">> := Response} = Input, _Opts) ->
    Rest = maps:get(<<"rest">>, Input, []),
    {ok, restore_json_links(Base), restore_json_links(Request),
        restore_json_links(Response), restore_json_links(Rest)};
verification_messages(_, _, _Opts) ->
    {error, <<"receipt does not contain recorded AO-Core messages">>}.

%% @doc Decode an unpadded base64url Erlang external term of a transcript
%% within the size limit. The checks run in this order: text size (which
%% bounds the decoded bytes to 1 MiB), base64url, compression, safe decoding,
%% the transcript's keys, and plain data (maps, lists, tuples, binaries,
%% atoms and numbers only).
decode_transcript_term(Text) when byte_size(Text) > ?MAX_TERM_TEXT_BYTES ->
    {error, <<"too-large">>};
decode_transcript_term(Text) ->
    case catch hb_util:decode(Text) of
        <<131, 80, _/binary>> ->
            {error, <<"compressed">>};
        Bin when is_binary(Bin) ->
            try binary_to_term(Bin, [safe]) of
                #{base := _, request := _, response := _} = Term ->
                    case plain_term(Term) of
                        true -> {ok, Term};
                        false -> {error, <<"unsupported-term">>}
                    end;
                _ ->
                    {error, <<"undecodable">>}
            catch _:_ -> {error, <<"undecodable">>}
            end;
        _ ->
            {error, <<"undecodable">>}
    end.

plain_term(Map) when is_map(Map) ->
    plain_list(maps:keys(Map)) andalso plain_list(maps:values(Map));
plain_term(List) when is_list(List) -> plain_list(List);
plain_term(Tuple) when is_tuple(Tuple) -> plain_list(tuple_to_list(Tuple));
plain_term(Value) ->
    is_binary(Value) orelse is_atom(Value) orelse is_number(Value).

plain_list([]) -> true;
plain_list([Value | Rest]) -> plain_term(Value) andalso plain_list(Rest);
plain_list(_Improper) -> false.

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

%% @doc Resolve a key of `inference@1.0' with the node's options. The caller's
%% request is not forwarded: these keys read nothing from it.
delegate(Key, Opts) ->
    hb_ao:resolve(?INFERENCE_BASE, #{<<"path">> => Key}, Opts).

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
execution_opts(Opts) ->
    Opts#{
        <<"hashpath">> => update,
        <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
    }.

%% @doc Reject streaming, execute the allowlisted request and decorate the
%% complete response.
decorate(Path, Req, Opts) ->
    ExecutionReq = execution_request(Path, Req, Opts),
    case truthy(maps:get(<<"stream">>, ExecutionReq, false)) of
        true ->
            error_reply(400, #{
                <<"error">> => <<"receipt-streaming-unsupported">>,
                <<"message">> =>
                    <<"receipt v1 requires a complete non-streaming response">>
            });
        false ->
            case hb_ao:resolve(?INFERENCE_BASE, ExecutionReq,
                    execution_opts(Opts)) of
                {ok, Response} -> add_receipt(Response, ExecutionReq, Opts);
                {error, _} = Error -> Error;
                {_Status, Reason} -> {error, Reason}
            end
    end.

%% @doc Attach the receipt after committing the original response body/data.
add_receipt(Response, ExecutionReq, Opts) when is_map(Response) ->
    Body = first_defined([
        hb_ao:get(<<"body">>, Response, undefined, Opts),
        hb_ao:get(<<"data">>, Response, <<>>, Opts)
    ]),
    Receipt = make_receipt(ExecutionReq, Body, Response, Opts),
    %% HTTP response encoding serializes the `body' field and can omit
    %% sibling AO-Core keys. The receipt is placed in the JSON body as well, so
    %% the public API and a publishing client carry the same evidence.
    BodyWithReceipt = body_with_receipt(Body, Receipt, Opts),
    {ok, maps:without([<<"body+link">>, <<"data+link">>], Response#{
        <<"body">> => BodyWithReceipt,
        <<"data">> => BodyWithReceipt,
        <<"receipt">> => Receipt
    })};
add_receipt(Response, _ExecutionReq, _Opts) ->
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

%% The receipt as a JSON client decodes it: absent values removed, links and
%% other tuples converted (json_safe/1), then encoded and decoded once. The
%% node commits this form, so `signed-receipt' verifies after the JSON body is
%% decoded.
json_form(Value) ->
    Safe = json_safe(Value),
    try hb_json:decode(hb_json:encode(Safe))
    catch _:_ -> Safe
    end.

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
json_safe(Value) when is_tuple(Value); is_pid(Value); is_reference(Value);
        is_port(Value); is_function(Value) ->
    iolist_to_binary(io_lib:format("~w", [Value]));
json_safe(Value) -> Value.

%% @doc Build and commit a request/response observation. Request-derived
%% fields come from the executed public request; the inventory and the
%% measurement are probed with the node's own configuration.
make_receipt(ExecutionReq, Body, Response, Opts) ->
    RequestDigest = digest(ExecutionReq),
    Inventory = resolve_inventory(Opts),
    Measurement = resolve_measurement(RequestDigest, Opts),
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
    Receipt0 = add_execution_bindings(ReceiptBase, ExecutionReq, Opts),
    Receipt1 = json_form(Receipt0#{
        <<"system-measurement">> => Measurement,
        <<"ao-core">> =>
            ao_core_evidence(?INFERENCE_BASE, ExecutionReq, Response, Opts),
        <<"device-chain">> => device_chain_evidence()
    }),
    Committed = try hb_message:commit(Receipt1, Opts)
    catch _:_ -> Receipt1
    end,
    Signed = Receipt1#{
        <<"receipt-id">> => hb_message:id(Committed, signed, Opts),
        <<"signed-receipt">> => Committed
    },
    %% The address that signed `signed-receipt': the node's identity.
    case safe_signers(Committed, Opts) of
        [NodeAddress | _] -> Signed#{<<"node-address">> => NodeAddress};
        [] -> Signed
    end.

%% @doc Expose AO-Core's execution link in terms a verifier can explain.
%% The hashpath is read from the resolved response private message; it is not
%% re-hashed by this device or by a publishing client.
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
            undefined -> ?HASHPATH_SOURCE;
            Source -> Source
        end,
        <<"hashpath">> => Hashpath,
        <<"hashpath-algorithm">> => hashpath_algorithm(Base),
        <<"request-id">> => safe_message_id(Req, none, Opts),
        <<"response-id">> => safe_message_id(Response, none, Opts),
        <<"commitment-device">> => commitment_device(Response, Opts),
        <<"signers">> => safe_signers(Response, Opts),
        <<"verification-input">> => #{
            <<"base">> => Base,
            <<"request">> => Req,
            <<"response">> => Response
        },
        %% JSON is the public transport representation. An opaque Erlang-term
        %% snapshot restores AO-Core private metadata, so the exact HyperBEAM
        %% verifier can run on a published receipt.
        <<"verification-input-term">> =>
            transcript_term(#{base => Base, request => Req, response => Response}),
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

%% The inference device can expose the AO-Core link in its JSON response
%% (inside `attestation.raw' for `tee=true'). It is used when the response
%% carries no private HashPath.
public_ao_core_evidence(Response, Opts) ->
    Json = case hb_ao:get(<<"body">>, Response, undefined, Opts) of
        Bin when is_binary(Bin) ->
            try hb_json:decode(Bin) catch _:_ -> #{} end;
        Map when is_map(Map) -> Map;
        _ -> #{}
    end,
    case Json of
        #{<<"ao-core">> := Evidence} when is_map(Evidence) -> Evidence;
        #{<<"attestation">> := #{<<"raw">> := Raw}} when is_binary(Raw) ->
            try hb_json:decode(Raw) of
                #{<<"ao-core">> := Evidence} when is_map(Evidence) -> Evidence;
                _ -> #{}
            catch _:_ -> #{}
            end;
        _ -> #{}
    end.

%% The uncompressed external term of the transcript, unpadded base64url, as
%% `verify-hashpath' accepts it; omitted when it exceeds that key's limit.
transcript_term(Transcript) ->
    Bin = term_to_binary(Transcript),
    case byte_size(Bin) =< ?MAX_TERM_BYTES of
        true -> hb_util:encode(Bin);
        false -> undefined
    end.

%% AO-Core chains a HashPath with the algorithm its base message names.
hashpath_algorithm(Base) ->
    case maps:get(<<"hashpath-alg">>, Base, undefined) of
        undefined -> <<"sha-256-chain (AO-Core default)">>;
        Value -> Value
    end.

commitment_device(Response, Opts) ->
    case catch hb_message:commitment_devices(Response, Opts) of
        [Device | _] -> Device;
        _ -> undefined
    end.

safe_signers(Message, Opts) ->
    case catch hb_message:signers(Message, Opts) of
        Signers when is_list(Signers) -> Signers;
        _ -> []
    end.

safe_message_id(Message, Committers, Opts) ->
    case catch hb_message:id(hb_private:reset(Message), Committers, Opts) of
        ID when is_binary(ID) -> ID;
        _ -> undefined
    end.

%% @doc Record which devices produced the receipt and its measurement.
%% `loader' names the toolchain that packages these devices.
device_chain_evidence() ->
    #{
        <<"status">> => <<"captured">>,
        <<"receipt-device">> => <<"inference_receipt@1.0">>,
        <<"measurement-device">> => <<"inference_measurement@1.0">>,
        <<"inventory-device">> => <<"gpu_inventory@1.0">>,
        <<"loader">> => <<"HyperBEAM Device Forge">>
    }.

%% Add execution-profile bindings to the signed receipt: the operator's node
%% option of the same name, else the executed request's declaration. Absent
%% bindings are omitted.
add_execution_bindings(Receipt, Req, Opts) ->
    lists:foldl(
        fun(Key, Acc) ->
            case first_defined([hb_opts:get(Key, undefined, Opts),
                    maps:get(Key, Req, undefined)]) of
                undefined -> Acc;
                Value -> Acc#{Key => Value}
            end
        end,
        Receipt,
        ?BINDING_KEYS
    ).

%% @doc Resolve the node's GPU inventory report.
resolve_inventory(Opts) ->
    probe(
        fun() ->
            {Base, Req} = inventory_probe(),
            {ok, Response} = hb_ao:resolve(Base, Req, Opts),
            result_body(Response, Opts)
        end
    ).

%% @doc Resolve a fresh measurement bound to this request digest.
resolve_measurement(RequestDigest, Opts) ->
    probe(
        fun() ->
            {Base, Req} = measurement_probe(RequestDigest),
            {ok, Response} = hb_ao:resolve(Base, Req, Opts),
            measurement_fields(result_body(Response, Opts), Opts)
        end
    ).

%% The probe messages. They carry nothing from the caller's request: the
%% inventory and measurement devices read their own node options.
inventory_probe() ->
    {#{<<"device">> => <<"gpu_inventory@1.0">>}, #{<<"path">> => <<"report">>}}.

measurement_probe(RequestDigest) ->
    {#{<<"device">> => <<"inference_measurement@1.0">>},
        #{<<"path">> => <<"fresh">>, <<"nonce">> => RequestDigest}}.

%% A probe that fails, or whose device is not loadable on this node,
%% contributes an empty object instead of failing the completion.
probe(Fun) ->
    try Fun()
    catch Class:Reason ->
        ?event(inference_receipt, {probe_unavailable, {Class, Reason}}),
        #{}
    end.

%% @doc The result message of a device that answers either bare or inside a
%% `{status, body}' envelope. Bare inventory and measurement results carry a
%% `type'; a measurement envelope's own `body' is its measured subject, so a
%% typed result is never unwrapped.
result_body(Result, Opts) when is_map(Result) ->
    case hb_maps:find(<<"type">>, Result, Opts) of
        {ok, _} -> Result;
        error ->
            case hb_maps:find(<<"body">>, Result, Opts) of
                {ok, Body} when is_map(Body) -> Body;
                {ok, Body} when is_binary(Body) ->
                    try hb_json:decode(Body) of
                        Decoded when is_map(Decoded) -> Decoded;
                        _ -> #{}
                    catch _:_ -> #{}
                    end;
                {ok, _} -> #{};
                error -> Result
            end
    end;
result_body(_Result, _Opts) ->
    #{}.

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
        <<"measurement-envelope">> => maps:get(<<"type">>, Body, undefined),
        <<"subject-id">> => maps:get(<<"subject-id">>, Composition, undefined),
        %% A composed envelope records the binding in its composition, an
        %% observation envelope at its top level.
        <<"nonce-binding">> => materialize_link(first_defined([
            maps:get(<<"nonce-binding">>, Composition, undefined),
            maps:get(<<"nonce-binding">>, Body, undefined)
        ]), Opts),
        %% The envelope exactly as `inference_measurement@1.0' returned it, so
        %% its `verify' key can check it.
        <<"envelope">> => materialize_link(Body, Opts),
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

%% @doc The unpadded base64url SHA-256 of a binary, or of the canonical JSON
%% encoding of any other value.
digest(Value) when is_binary(Value) ->
    hb_util:encode(crypto:hash(sha256, Value));
digest(Value) ->
    hb_util:encode(crypto:hash(sha256, canonical_json(Value))).

%% @doc OTP `json' encoding with the members of every object in ascending
%% byte order of their keys. `json:encode/1' orders only objects of up to 32
%% members, so larger objects are ordered here.
canonical_json(Value) ->
    iolist_to_binary(json:encode(Value, fun canonical_value/2)).

canonical_value(Map, Encode) when is_map(Map) ->
    json:encode_key_value_list(
        lists:sort([{json_key(Key), Value} || {Key, Value} <- maps:to_list(Map)]),
        Encode);
canonical_value(Value, Encode) ->
    json:encode_value(Value, Encode).

json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
json_key(Key) when is_integer(Key) -> integer_to_binary(Key).

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

-define(CHAT_RESPONSE, <<"{\"object\":\"chat.completion\",\"model\":\"runtime-model\","
    "\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"message\":"
    "{\"role\":\"assistant\",\"content\":\"ok\"}}]}">>).

runtime_endpoints() ->
    [
        {"/v1/chat/completions", chat, {200, ?CHAT_RESPONSE}},
        {"/v1/models", models, {200, <<"{\"object\":\"list\",\"data\":[]}">>}},
        {"/health", health, {200, <<>>}}
    ].

%% Node options for a runtime at `URL'. `hashpath: ignore' mirrors the
%% reference deployment, which disables HashPaths globally.
node_opts(URL) ->
    #{
        <<"inference-peer">> => URL,
        <<"hashpath">> => ignore,
        <<"priv-wallet">> => ar_wallet:new(),
        <<"store">> => hb_test_utils:test_store()
    }.

with_runtime(Fun) ->
    {ok, URL, Handle} = hb_mock_server:start(runtime_endpoints()),
    try Fun(URL, Handle)
    after hb_mock_server:stop(Handle)
    end.

%% An attestation device that reports the nonce it was asked to bind.
stub_attestation_device(Parent, Ref) ->
    #{
        <<"generate">> =>
            fun(_Base, Req, _Opts) ->
                Nonce = hb_maps:get(<<"nonce">>, Req, undefined, #{}),
                Parent ! {attested_nonce, Ref, Nonce},
                {ok, hb_json:encode(#{
                    <<"verified">> => true,
                    <<"claims">> => [#{<<"eat_nonce">> => Nonce}]
                })}
            end
    }.

info_lists_exactly_the_resolvable_keys_test() ->
    #{exports := Exports} = info(#{}),
    ?assertEqual(
        lists:sort([<<"completions">>, <<"chat">>, <<"v1">>, <<"models">>,
            <<"health">>, <<"verify-hashpath">>, <<"publish">>]),
        lists:sort(Exports)),
    [?assert(erlang:function_exported(?MODULE,
            binary_to_atom(binary:replace(Key, <<"-">>, <<"_">>)), 3))
        || Key <- Exports].

receipt_excludes_transport_fields_and_verifies_test_() ->
    {timeout, 60, fun() ->
        with_runtime(fun(URL, _Handle) ->
            Ref = make_ref(),
            Opts = (node_opts(URL))#{
                <<"inference-attestation-device">> =>
                    stub_attestation_device(self(), Ref)
            },
            {ok, Result} = completions(#{}, leaky_request(), Opts),
            assert_no_transport_leak(Result),
            #{<<"ao-core">> := AOCore, <<"request-digest">> := RequestDigest,
                <<"device-chain">> := DeviceChain,
                <<"node-address">> := NodeAddress} =
                    maps:get(<<"receipt">>, Result),
            ?assertEqual(
                hb_util:human_id(ar_wallet:to_address(
                    maps:get(<<"priv-wallet">>, Opts))),
                NodeAddress),
            ?assertEqual(NodeAddress, node_address(Opts)),
            ?assertNot(maps:is_key(<<"implementation-id">>, DeviceChain)),
            ?assertEqual(<<"HyperBEAM Device Forge">>,
                maps:get(<<"loader">>, DeviceChain)),
            ?assertEqual(?HASHPATH_SOURCE, maps:get(<<"source">>, AOCore)),
            Term = maps:get(<<"verification-input-term">>, AOCore),
            %% The term is uncompressed, as `verify-hashpath' requires.
            ?assertMatch(<<131, Tag, _/binary>> when Tag =/= 80,
                hb_util:decode(Term)),
            Transcript = binary_to_term(hb_util:decode(Term), [safe]),
            assert_no_transport_leak(Transcript),
            %% Verifiers can recompute the request digest from the transcript.
            ?assertEqual(RequestDigest, digest(maps:get(request, Transcript))),
            ?assertEqual(<<"verified">>,
                maps:get(<<"verification-status">>, AOCore)),
            {ok, #{<<"body">> := Verification}} = verify_hashpath(#{},
                #{<<"verification-input-term">> => Term}, Opts),
            ?assertEqual(true, maps:get(<<"verified">>, Verification)),
            %% `tee=true' attests the same response: the report is bound to
            %% the SHA-256 of the published `raw'.
            #{<<"attestation">> := #{<<"raw">> := Raw, <<"nonce">> := Nonce,
                <<"verified">> := true}, <<"receipt">> := JsonReceipt} =
                    hb_json:decode(maps:get(<<"body">>, Result)),
            %% The signed receipt verifies in the message and in the JSON
            %% body, and its only signer is `node-address'.
            assert_signed_by(NodeAddress,
                maps:get(<<"signed-receipt">>, maps:get(<<"receipt">>, Result)),
                Opts),
            assert_signed_by(NodeAddress,
                maps:get(<<"signed-receipt">>, JsonReceipt), Opts),
            ?assertEqual(
                maps:without([<<"signed-receipt">>], maps:get(<<"receipt">>, Result)),
                maps:without([<<"signed-receipt">>], JsonReceipt)),
            %% `inference@1.0' publishes in `raw' the HashPath of the step
            %% AO-Core executed: the executed request carries no client
            %% metadata.
            #{<<"ao-core">> := RawAOCore} = hb_json:decode(Raw),
            ?assertEqual(maps:get(<<"hashpath">>, AOCore),
                maps:get(<<"hashpath">>, RawAOCore)),
            ?assertEqual(maps:get(<<"request-id">>, AOCore),
                maps:get(<<"request-id">>, RawAOCore)),
            %% `publish' accepts this receipt, bare or inside a publication
            %% record that carries it under `report.receipt'.
            Bare = hb_json:encode(JsonReceipt),
            Record = hb_json:encode(#{
                <<"report">> => #{<<"receipt">> =>
                    JsonReceipt#{<<"version">> => <<"1">>}},
                <<"attestation">> => #{<<"raw">> => Raw}
            }),
            ?assertEqual({ok, Bare}, publishable_document(Bare, Opts)),
            ?assertEqual({ok, Record}, publishable_document(Record, Opts)),
            ?assertMatch({error, 422, #{<<"error">> := <<"receipt-node-mismatch">>}},
                publishable_document(hb_json:encode(JsonReceipt#{
                    <<"node-address">> => hb_util:human_id(
                        ar_wallet:to_address(ar_wallet:new()))}), Opts)),
            ?assertEqual(hb_util:to_hex(hb_crypto:sha256(Raw)), Nonce),
            ?assertEqual(Nonce,
                receive {attested_nonce, Ref, Asked} -> Asked
                after 5000 -> no_attestation_request
                end)
        end)
    end}.

%% Node options that give `inference_measurement@1.0' stand-in inventory,
%% GPU TEE and base measurement devices.
measurement_opts(URL, BaseDevice) ->
    Inventory = #{
        <<"type">> => <<"apus-gpu-inventory">>,
        <<"version">> => <<"1.0">>,
        <<"supported">> => true,
        <<"devices">> => [#{<<"pci-bdf">> => <<"0000:01:00.0">>}],
        <<"inventory-digest">> => <<"OQ6jjieUQbTtI-MX-ai4cEGhp-ZwEo9lm1fYxyB51uk">>,
        <<"errors">> => []
    },
    GpuTee = #{
        <<"generate">> => fun(_Base, Req, _Opts) ->
            Nonce = hb_maps:get(<<"nonce">>, Req, undefined, #{}),
            {ok, hb_json:encode(#{
                <<"nonce">> => Nonce,
                <<"verified">> => true,
                <<"evidences">> => [#{<<"nonce">> => Nonce}],
                <<"claims">> => [#{<<"eat_nonce">> => Nonce}]
            })}
        end,
        <<"verify">> => fun(_Base, _Req, _Opts) -> {ok, <<"true">>} end
    },
    (node_opts(URL))#{
        <<"inference-measurement-inventory-device">> =>
            #{<<"report">> => fun(_, _, _) -> {ok, Inventory} end},
        <<"inference-measurement-gpu-tee-device">> => GpuTee,
        <<"inference-measurement-base-device">> => BaseDevice,
        <<"inference-measurement-sev-guest-path">> => <<"/nonexistent/sev-guest">>
    }.

%% A stand-in base measurement device whose report carries the nonce it was
%% asked to measure, and whose `verify' checks that nonce.
base_measurement_stub() ->
    #{
        <<"info">> => fun(_, _, _) -> {ok, #{<<"version">> => <<"1">>}} end,
        <<"fresh">> => fun(_, Req, _) ->
            {ok, #{
                <<"type">> => <<"lapee-measurement">>,
                <<"measurement-device">> => <<"snp@1.0">>,
                <<"body">> => #{<<"system">> => #{<<"os">> => <<"linux">>}},
                <<"evidence">> => #{
                    <<"report-raw">> => <<"report">>,
                    <<"nonce">> => hb_maps:get(<<"nonce">>, Req, undefined, #{})
                }
            }}
        end,
        <<"verify">> => fun(_, Req, _) ->
            Envelope = hb_maps:get(<<"envelope">>, Req, #{}, #{}),
            Evidence = hb_maps:get(<<"evidence">>, Envelope, #{}, #{}),
            Verified = case hb_maps:get(<<"nonce">>, Req, undefined, #{}) of
                undefined -> true;
                Nonce -> Nonce =:= hb_maps:get(<<"nonce">>, Evidence, none, #{})
            end,
            {ok, #{<<"status">> => 200, <<"body">> => #{<<"verified">> => Verified}}}
        end
    }.

%% The receipt records the measurement envelope exactly as
%% `inference_measurement@1.0' returned it: posted back to its `verify' key,
%% the envelope from the JSON body verifies, for an observation and for a
%% composed measurement. `nonce-binding' binds the request digest.
receipt_measurement_envelope_verifies_test_() ->
    {timeout, 60, fun() ->
        with_runtime(fun(URL, _Handle) ->
            Chat = #{
                <<"model">> => <<"test-model">>,
                <<"messages">> =>
                    [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
            },
            lists:foreach(
                fun({BaseDevice, Type, Status}) ->
                    Opts = measurement_opts(URL, BaseDevice),
                    {ok, Result} = completions(#{}, Chat, Opts),
                    #{<<"receipt">> := Receipt} =
                        hb_json:decode(maps:get(<<"body">>, Result)),
                    #{<<"request-digest">> := RequestDigest,
                        <<"system-measurement">> := Measurement} = Receipt,
                    #{<<"envelope">> := Envelope} = Measurement,
                    ?assertEqual(Type, maps:get(<<"type">>, Envelope)),
                    ?assertEqual(Type,
                        maps:get(<<"measurement-envelope">>, Measurement)),
                    ?assertEqual(Status, maps:get(<<"status">>, Measurement)),
                    ?assertEqual(RequestDigest, maps:get(<<"request-nonce">>,
                        maps:get(<<"nonce-binding">>, Measurement))),
                    ?assertEqual(maps:get(<<"gpu-tee">>, Envelope),
                        maps:get(<<"gpu-tee">>, Measurement)),
                    ?assertEqual(maps:get(<<"cpu-tee">>, Envelope),
                        maps:get(<<"cpu-tee">>, Measurement)),
                    {ok, Verification} = hb_ao:resolve(
                        #{<<"device">> => <<"inference_measurement@1.0">>},
                        #{<<"path">> => <<"verify">>, <<"envelope">> => Envelope},
                        Opts),
                    ?assertMatch(#{<<"verified">> := true,
                            <<"nonce-binding-verified">> := true},
                        Verification),
                    case Type of
                        <<"lapee-measurement">> ->
                            ?assertMatch(#{<<"nonce-binding-hardware-bound">> := true},
                                Verification);
                        _ ->
                            ?assertMatch(#{<<"signature-verified">> := true},
                                Verification)
                    end
                end,
                [
                    {#{}, <<"apus-gpu-system-measurement">>, <<"observed">>},
                    {base_measurement_stub(), <<"lapee-measurement">>,
                        <<"measured">>}
                ])
        end)
    end}.

request_and_base_cannot_select_the_runtime_test_() ->
    {timeout, 60, fun() ->
        {ok, Diverted, DivertedHandle} =
            hb_mock_server:start([{"/[...]", diverted}]),
        try
            with_runtime(fun(URL, Handle) ->
                Override = #{
                    <<"agent-api-peer">> => Diverted,
                    <<"agent-api-path">> => <<"/diverted">>,
                    <<"agent-api-key">> => <<"caller-key">>,
                    <<"inference-peer">> => Diverted,
                    <<"inference-path">> => <<"/diverted">>,
                    <<"inference-api-key">> => <<"caller-key">>,
                    <<"inference-attestation-device">> => <<"diverted@1.0">>,
                    <<"gpu-inventory-root">> => <<"/diverted">>,
                    <<"measurement-mode">> => <<"diverted">>
                },
                Ref = make_ref(),
                Opts = (node_opts(URL))#{
                    <<"inference-api-key">> => <<"operator-key">>,
                    <<"inference-attestation-device">> =>
                        stub_attestation_device(self(), Ref)
                },
                Base = Override#{<<"device">> => <<"inference_receipt@1.0">>},
                Chat = #{
                    <<"model">> => <<"test-model">>,
                    <<"messages">> =>
                        [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
                    <<"tee">> => true
                },
                {ok, Result} = hb_ao:resolve(Base, maps:merge(Chat,
                    Override#{<<"path">> => <<"completions">>}), Opts),
                %% None of the override keys entered the executed request.
                #{<<"ao-core">> := #{<<"verification-input">> :=
                    #{<<"request">> := Executed}}} = maps:get(<<"receipt">>, Result),
                ?assertEqual([], [Key || Key <- maps:keys(Override),
                    maps:is_key(Key, Executed)]),
                %% The operator's attestation device answered.
                #{<<"attestation">> := #{<<"verified">> := true,
                    <<"nonce">> := Nonce}} =
                        hb_json:decode(maps:get(<<"body">>, Result)),
                ?assertEqual(Nonce, receive {attested_nonce, Ref, Asked} -> Asked
                    after 5000 -> no_attestation_request end),
                {ok, _} = hb_ao:resolve(Base,
                    Override#{<<"path">> => <<"models">>}, Opts),
                {ok, _} = hb_ao:resolve(Base,
                    Override#{<<"path">> => <<"health">>}, Opts),
                [Sent] = hb_mock_server:get_requests(chat, 1, Handle),
                ?assertMatch(#{<<"authorization">> := <<"Bearer operator-key">>},
                    maps:get(<<"headers">>, Sent)),
                ?assertMatch([_], hb_mock_server:get_requests(models, 1, Handle)),
                ?assertMatch([_], hb_mock_server:get_requests(health, 1, Handle)),
                ?assertEqual([],
                    hb_mock_server:get_requests(DivertedHandle, diverted))
            end)
        after
            hb_mock_server:stop(DivertedHandle)
        end
    end}.

%% Every key the receipt admits as a generation parameter reaches the runtime
%% through `inference@1.0', and the `user' identifier does not.
receipt_relays_every_generation_key_test_() ->
    {timeout, 60, fun() ->
        with_runtime(fun(URL, Handle) ->
            Request = maps:from_list([{Key, generation_value(Key)}
                || Key <- ?GENERATION_KEYS]),
            {ok, _} = completions(#{},
                Request#{<<"user">> => <<"leak-test-user">>}, node_opts(URL)),
            [Sent] = hb_mock_server:get_requests(chat, 1, Handle),
            Relayed = hb_json:decode(maps:get(<<"body">>, Sent)),
            ?assertEqual(lists:sort(?GENERATION_KEYS),
                lists:sort(maps:keys(Relayed)))
        end)
    end}.

generation_value(<<"stream">>) -> false;
generation_value(<<"messages">>) ->
    [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}];
generation_value(_Key) -> <<"value">>.

%% The status and decoded JSON body of an error result.
error_json({error, #{<<"status">> := Status, <<"content-type">> := ?JSON,
        <<"body">> := Body}}) ->
    {Status, hb_json:decode(Body)}.

streaming_request_is_rejected_test() ->
    lists:foreach(
        fun(Req) ->
            ?assertMatch({400, #{
                    <<"error">> := <<"receipt-streaming-unsupported">>,
                    <<"message">> := _}},
                error_json(completions(#{}, Req, #{})))
        end,
        [#{<<"stream">> => true},
            #{<<"body">> => <<"{\"stream\":true}">>}]).

result_body_accepts_bare_and_enveloped_results_test() ->
    Inventory = #{<<"type">> => <<"apus-gpu-inventory">>,
        <<"inventory-digest">> => <<"digest">>},
    ?assertEqual(Inventory, result_body(Inventory, #{})),
    ?assertEqual(Inventory,
        result_body(#{<<"status">> => 200, <<"body">> => Inventory}, #{})),
    %% A bare measurement envelope's `body' is its subject, not a wrapper.
    Envelope = #{<<"type">> => <<"lapee-measurement">>,
        <<"body">> => #{<<"system">> => #{}}},
    ?assertEqual(Envelope, result_body(Envelope, #{})),
    ?assertEqual(Envelope,
        result_body(#{<<"status">> => 200, <<"body">> => Envelope}, #{})),
    ?assertEqual(#{}, result_body(not_a_message, #{})).

probes_carry_only_a_path_and_the_request_digest_test() ->
    ?assertEqual(
        {#{<<"device">> => <<"gpu_inventory@1.0">>},
            #{<<"path">> => <<"report">>}},
        inventory_probe()),
    ?assertEqual(
        {#{<<"device">> => <<"inference_measurement@1.0">>},
            #{<<"path">> => <<"fresh">>, <<"nonce">> => <<"digest">>}},
        measurement_probe(<<"digest">>)).

%% `Signed' verifies and `Address' is its only signer.
assert_signed_by(Address, Signed, Opts) ->
    ?assert(hb_message:verify(Signed, all, Opts)),
    ?assertEqual([Address], hb_message:signers(Signed, Opts)).

%% The wire contract seen by HTTP clients: plain and attested completions,
%% streaming refusal, health, the model list, a receipt and its HashPath
%% verification, all through a node's HTTP server.
http_round_trip_test_() ->
    {timeout, 120, fun() ->
        with_runtime(fun(Runtime, _Handle) ->
            Ref = make_ref(),
            Node = hb_http_server:start_node((node_opts(Runtime))#{
                <<"port">> => 0,
                <<"inference-attestation-device">> =>
                    stub_attestation_device(self(), Ref)
            }),
            Chat = #{
                <<"model">> => <<"test-model">>,
                <<"messages">> =>
                    [#{<<"role">> => <<"user">>, <<"content">> => <<"ping">>}],
                <<"max_tokens">> => 4
            },
            {200, Plain} = http_post(Node,
                "~inference@1.0/v1/chat/completions", Chat),
            ?assertMatch(#{<<"choices">> := [_]}, Plain),
            ?assertNot(maps:is_key(<<"attestation">>, Plain)),
            {400, Refused} = http_post(Node,
                "~inference@1.0/v1/chat/completions",
                Chat#{<<"stream">> => true}),
            ?assertMatch(#{<<"error">> :=
                    #{<<"code">> := <<"streaming_unsupported">>}}, Refused),
            {200, Attested} = http_post(Node,
                "~inference@1.0/v1/chat/completions?tee=true", Chat),
            #{<<"attestation">> := #{<<"raw">> := Raw, <<"nonce">> := Nonce},
                <<"resolved_model">> := #{<<"model">> := <<"runtime-model">>}} =
                    Attested,
            ?assertEqual(hb_util:to_hex(hb_crypto:sha256(Raw)), Nonce),
            ?assertEqual(Nonce, receive {attested_nonce, Ref, Asked} -> Asked
                after 5000 -> no_attestation_request end),
            ?assertEqual(
                lists:sort([<<"max_tokens">>, <<"messages">>, <<"model">>,
                    <<"tee">>]),
                lists:sort(maps:keys(maps:get(<<"request">>,
                    hb_json:decode(Raw))))),
            %% The published AO-Core evidence does not depend on the caller's
            %% address or client headers.
            RawAOCore = fun(Headers) ->
                {200, #{<<"attestation">> := #{<<"raw">> := R}}} = http_post(
                    Node, "~inference@1.0/v1/chat/completions?tee=true", Chat,
                    Headers),
                maps:get(<<"ao-core">>, hb_json:decode(R))
            end,
            First = RawAOCore([{"x-real-ip", "203.0.113.77"},
                {"x-forwarded-for", "203.0.113.77"}, {"user-agent", "agent-a"}]),
            ?assertMatch(#{<<"status">> := <<"captured">>, <<"hashpath">> := _,
                <<"request-id">> := _}, First),
            ?assertEqual(First, RawAOCore([{"x-real-ip", "203.0.113.78"},
                {"x-forwarded-for", "198.51.100.20"}, {"user-agent", "agent-b"}])),
            {200, _} = http_get(Node, "~inference@1.0/health"),
            {200, Models} = http_get(Node, "~inference@1.0/v1/models"),
            ?assertMatch(#{<<"object">> := <<"list">>}, Models),
            %% The receipt device's errors carry their JSON bodies.
            ?assertMatch({400, #{<<"error">> :=
                    <<"receipt-streaming-unsupported">>}},
                http_post(Node, "~inference_receipt@1.0/v1/chat/completions",
                    Chat#{<<"stream">> => true})),
            Compressed = hb_util:encode(term_to_binary(#{base => #{},
                request => #{<<"body">> => binary:copy(<<"a">>, 100000)},
                response => #{}}, [compressed])),
            ?assertMatch({400, #{<<"verified">> := false,
                    <<"error">> := <<"invalid-verification-input-term">>,
                    <<"reason">> := <<"compressed">>}},
                http_post(Node, "~inference_receipt@1.0/verify-hashpath",
                    #{<<"verification-input-term">> => Compressed})),
            {200, WithReceipt} = http_post(Node,
                "~inference_receipt@1.0/v1/chat/completions", Chat),
            #{<<"choices">> := [_], <<"receipt">> := Receipt} = WithReceipt,
            #{<<"node-address">> := NodeAddress, <<"ao-core">> := AOCore,
                <<"signed-receipt">> := SignedReceipt} = Receipt,
            ?assertEqual(43, byte_size(NodeAddress)),
            assert_signed_by(NodeAddress, SignedReceipt, #{}),
            ?assertEqual(<<"verified">>,
                maps:get(<<"verification-status">>, AOCore)),
            {200, Verification} = http_post(Node,
                "~inference_receipt@1.0/verify-hashpath",
                #{<<"ao-core">> => AOCore}),
            %% The HTTP encoding types `verified' through `ao-types', so a
            %% JSON client reads the string "true".
            ?assertEqual(true, truthy(maps:get(<<"verified">>,
                maps:get(<<"body">>, Verification, Verification))))
        end)
    end}.

http_post(Node, Path, Json) ->
    http_post(Node, Path, Json, []).

http_post(Node, Path, Json, Headers) ->
    http_reply(httpc:request(post,
        {binary_to_list(Node) ++ Path,
            [{"accept", "application/json"}, {"accept-bundle", "true"} | Headers],
            "application/json", hb_json:encode(Json)},
        [{timeout, 60000}], [{body_format, binary}])).

http_get(Node, Path) ->
    http_reply(httpc:request(get,
        {binary_to_list(Node) ++ Path,
            [{"accept", "application/json"}, {"accept-bundle", "true"}]},
        [{timeout, 60000}], [{body_format, binary}])).

http_reply({ok, {{_, Status, _}, _Headers, Body}}) ->
    {Status, first_json_object(Body)}.

%% Clients read the first JSON object of a reply, which may be multipart.
first_json_object(Body) ->
    case binary:match(Body, <<"{">>) of
        nomatch -> Body;
        {Start, _} ->
            Rest = binary:part(Body, Start, byte_size(Body) - Start),
            hb_json:decode(binary:part(Rest, 0, object_length(Rest, 0, 0, false)))
    end.

object_length(<<$\\, _, Rest/binary>>, Pos, Depth, true) ->
    object_length(Rest, Pos + 2, Depth, true);
object_length(<<$", Rest/binary>>, Pos, Depth, InString) ->
    object_length(Rest, Pos + 1, Depth, not InString);
object_length(<<_, Rest/binary>>, Pos, Depth, true) ->
    object_length(Rest, Pos + 1, Depth, true);
object_length(<<${, Rest/binary>>, Pos, Depth, false) ->
    object_length(Rest, Pos + 1, Depth + 1, false);
object_length(<<$}, _/binary>>, Pos, 1, false) ->
    Pos + 1;
object_length(<<$}, Rest/binary>>, Pos, Depth, false) ->
    object_length(Rest, Pos + 1, Depth - 1, false);
object_length(<<_, Rest/binary>>, Pos, Depth, false) ->
    object_length(Rest, Pos + 1, Depth, false);
object_length(<<>>, Pos, _Depth, _InString) ->
    Pos.

unavailable_probes_contribute_empty_objects_test() ->
    ?assertEqual(#{}, probe(fun() -> error({badmatch, {error, not_found}}) end)),
    ?assertEqual(#{}, probe(fun() -> throw({device_not_loadable, x}) end)),
    ?assertEqual(#{<<"type">> => <<"t">>},
        probe(fun() -> #{<<"type">> => <<"t">>} end)).

publish_requires_a_receipt_test() ->
    ?assertEqual({400, #{<<"error">> => <<"receipt-required">>}},
        error_json(publish(#{}, leaky_request(), #{}))).

%% A receipt document with the keys `publish' requires, naming `Address'.
receipt_document(Address) ->
    #{
        <<"type">> => <<"apus-inference-receipt">>,
        <<"version">> => <<"1.0">>,
        <<"receipt-id">> => hb_util:encode(crypto:strong_rand_bytes(32)),
        <<"request-digest">> => digest(<<"request">>),
        <<"response-digest">> => digest(<<"response">>),
        <<"node-address">> => Address,
        <<"ao-core">> => #{<<"status">> => <<"not-captured">>},
        <<"signed-receipt">> => #{<<"type">> => <<"apus-inference-receipt">>}
    }.

wallet_address(Wallet) ->
    hb_util:human_id(ar_wallet:to_address(Wallet)).

%% Only a document that carries a receipt naming this node, within the size
%% limit, is signed; nothing reaches the bundler otherwise.
publish_accepts_only_receipts_of_this_node_test() ->
    Wallet = ar_wallet:new(),
    Opts = #{<<"priv-wallet">> => Wallet},
    Receipt = receipt_document(wallet_address(Wallet)),
    Publish = fun(Value) ->
        error_json(publish(#{}, #{<<"receipt">> => Value}, Opts))
    end,
    Invalid = fun(Reason) ->
        {422, #{<<"error">> => <<"receipt-invalid">>, <<"reason">> => Reason}}
    end,
    ?assertEqual(Invalid(<<"not-a-json-object">>), Publish(<<"not json">>)),
    ?assertEqual(Invalid(<<"not-a-json-object">>), Publish(<<"[1]">>)),
    ?assertEqual(Invalid(<<"receipt-not-found">>),
        Publish(<<"{\"type\":\"other\"}">>)),
    ?assertEqual(Invalid(<<"invalid-type">>), Publish(hb_json:encode(
        #{<<"report">> => #{<<"receipt">> => Receipt#{<<"type">> => <<"other">>}}}))),
    ?assertEqual(Invalid(<<"invalid-signed-receipt">>),
        Publish(hb_json:encode(maps:remove(<<"signed-receipt">>, Receipt)))),
    ?assertEqual(Invalid(<<"invalid-node-address">>),
        Publish(hb_json:encode(Receipt#{<<"node-address">> => 7}))),
    ?assertEqual({422, #{<<"error">> => <<"receipt-node-mismatch">>}},
        Publish(hb_json:encode(Receipt#{<<"node-address">> =>
            wallet_address(ar_wallet:new())}))),
    ?assertEqual({422, #{<<"error">> => <<"receipt-node-mismatch">>}},
        error_json(publish(#{}, #{<<"receipt">> => hb_json:encode(Receipt)},
            #{}))),
    Oversized = <<"{\"pad\":\"", (binary:copy(<<"a">>, ?MAX_PUBLISH_BYTES))/binary,
        "\"}">>,
    ?assertEqual({413, #{<<"error">> => <<"receipt-too-large">>,
            <<"limit">> => ?MAX_PUBLISH_BYTES}},
        Publish(Oversized)),
    ?assertEqual({ok, hb_json:encode(Receipt)},
        publishable_document(Receipt, Opts)).

%% The reference gateway publishes a record for every attested completion.
%% A record of an `inference@1.0' completion carries no node receipt; it is
%% accepted when its attestation nonce is the SHA-256 of its `raw' document.
publish_accepts_attestation_records_bound_to_raw_test() ->
    Opts = #{<<"priv-wallet">> => ar_wallet:new()},
    Raw = <<"{\"request\":{\"model\":\"m\"},\"tee\":true}">>,
    Nonce = binary:encode_hex(crypto:hash(sha256, Raw), lowercase),
    Attestation = #{<<"raw">> => Raw, <<"nonce">> => Nonce,
        <<"evidences">> => [#{<<"evidence">> => <<"e">>}]},
    Record = fun(A) ->
        hb_json:encode(#{
            <<"report">> => #{<<"receipt">> =>
                #{<<"type">> => ?RECEIPT_TYPE, <<"receipt-id">> => <<"r">>}},
            <<"attestation">> => A
        })
    end,
    ?assertMatch({ok, _}, publishable_document(Record(Attestation), Opts)),
    ?assertMatch({error, 422, _}, publishable_document(
        Record(Attestation#{<<"nonce">> => binary:copy(<<"0">>, 64)}), Opts)),
    ?assertMatch({error, 422, _}, publishable_document(
        Record(Attestation#{<<"evidences">> => []}), Opts)),
    ?assertMatch({error, 422, _}, publishable_document(
        Record(maps:remove(<<"raw">>, Attestation)), Opts)).

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
            Wallet = ar_wallet:new(),
            Opts = NodeOpts#{<<"priv-wallet">> => Wallet,
                <<"store">> => hb_test_utils:test_store()},
            spawn_link(fun() ->
                Parent ! {published, publish(#{}, #{<<"receipt">> =>
                    receipt_document(wallet_address(Wallet))}, Opts)}
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

publisher_allowlist_requires_a_verified_listed_signer_test() ->
    Publisher = ar_wallet:new(),
    Address = hb_util:human_id(ar_wallet:to_address(Publisher)),
    Opts = #{<<"receipt-publishers">> => [Address]},
    Request = #{<<"receipt">> => <<"{\"type\":\"apus-inference-receipt\"}">>},
    Signed = hb_message:commit(Request, #{<<"priv-wallet">> => Publisher}),
    ?assert(authorized_publisher(Signed, Opts)),
    ?assertNot(authorized_publisher(Request, Opts)),
    ?assertNot(authorized_publisher(
        hb_message:commit(Request, #{<<"priv-wallet">> => ar_wallet:new()}),
        Opts)),
    %% A commitment that names a listed signer must also verify, and must
    %% cover the published key.
    ?assertNot(authorized_publisher(
        Signed#{<<"receipt">> => <<"{\"type\":\"other\"}">>}, Opts)),
    ?assertNot(authorized_publisher(
        (hb_message:commit(#{<<"note">> => <<"x">>},
            #{<<"priv-wallet">> => Publisher}))#{
                <<"receipt">> => <<"{}">>}, Opts)),
    ?assertNot(authorized_publisher(Signed, #{<<"receipt-publishers">> => []})),
    ?assert(authorized_publisher(Request, #{})),
    ?assertEqual({403, #{<<"error">> => <<"receipt-publisher-not-allowed">>}},
        error_json(publish(#{}, Request, Opts))).

%% Over HTTP, only a request whose `receipt' a listed address signed is
%% published. The publisher commits to the published key, not to `path'.
publish_over_http_honours_the_allowlist_test_() ->
    {timeout, 60, fun() ->
        {Server, GatewayOpts} = hb_mock_server:start_arweave_gateway(#{
            price => {200, <<"12345">>},
            tx_anchor => {200, hb_util:encode(crypto:strong_rand_bytes(32))},
            chunk => {200, <<"OK">>}
        }),
        try
            Publisher = ar_wallet:new(),
            NodeWallet = ar_wallet:new(),
            Node = hb_http_server:start_node(GatewayOpts#{
                <<"port">> => 0,
                <<"priv-wallet">> => NodeWallet,
                <<"store">> => hb_test_utils:test_store(),
                %% Keep signed requests out of the working directory.
                <<"store-all-signed">> => false,
                <<"receipt-publishers">> =>
                    [hb_util:human_id(ar_wallet:to_address(Publisher))]
            }),
            ClientOpts = #{<<"store">> => hb_test_utils:test_store()},
            Path = <<"/~inference_receipt@1.0/publish">>,
            %% A publication record that carries the receipt under
            %% `report.receipt', sent as JSON text.
            Request = #{<<"receipt">> => hb_json:encode(#{<<"report">> =>
                #{<<"receipt">> => receipt_document(wallet_address(NodeWallet))}})},
            Post = fun(Msg) -> hb_http:post(Node, Path, Msg, ClientOpts) end,
            SignedBy = fun(Wallet, Msg) ->
                hb_message:commit(Msg, ClientOpts#{<<"priv-wallet">> => Wallet})
            end,
            Refused = [
                Post(Request),
                Post(SignedBy(ar_wallet:new(), Request)),
                Post(SignedBy(Publisher, Request#{<<"path">> => Path}))
            ],
            [?assertMatch({error, #{<<"status">> := 403}}, Result)
                || Result <- Refused],
            ?assertMatch({ok, #{<<"id">> := _, <<"bundle-id">> := _,
                    <<"bundle-status">> := <<"complete">>}},
                Post(SignedBy(Publisher, Request)))
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
    ?assertEqual({422, #{<<"verified">> => false,
            <<"error">> => <<"invalid-hashpath-transcript">>}},
        error_json(verify_hashpath(#{},
            #{<<"verification-input-term">> => Term}, #{}))),
    ?assertMatch({422, #{<<"verified">> := false,
            <<"error">> := <<"hashpath-verification-input-missing">>}},
        error_json(verify_hashpath(#{}, #{}, #{}))).

%% `verification-input-term' is unauthenticated: oversized and compressed
%% terms are refused before decoding, and only plain data is accepted.
verify_hashpath_bounds_the_erlang_term_test() ->
    Reason = fun(Text) ->
        {400, #{<<"verified">> := false,
            <<"error">> := <<"invalid-verification-input-term">>,
            <<"reason">> := Result}} = error_json(verify_hashpath(#{},
                #{<<"verification-input-term">> => Text}, #{})),
        Result
    end,
    Encode = fun(Term, Options) ->
        hb_util:encode(term_to_binary(Term, Options))
    end,
    Transcript = fun(Request) ->
        #{base => #{}, request => Request, response => #{}}
    end,
    ?assertEqual(<<"too-large">>,
        Reason(binary:copy(<<"A">>, ?MAX_TERM_TEXT_BYTES + 1))),
    ?assertEqual(<<"too-large">>, Reason(Encode(Transcript(#{<<"body">> =>
        binary:copy(<<"a">>, ?MAX_TERM_BYTES)}), []))),
    Compressed = Encode(Transcript(#{<<"body">> =>
        binary:copy(<<"a">>, 100000)}), [compressed]),
    ?assertMatch(<<131, 80, _/binary>>, hb_util:decode(Compressed)),
    ?assertEqual(<<"compressed">>, Reason(Compressed)),
    ?assertEqual(<<"unsupported-term">>,
        Reason(Encode(Transcript(#{<<"from">> => self()}), []))),
    ?assertEqual(<<"unsupported-term">>,
        Reason(Encode(Transcript(#{<<"f">> => fun() -> ok end}), []))),
    ?assertEqual(<<"unsupported-term">>,
        Reason(Encode(Transcript(#{<<"r">> => make_ref()}), []))),
    ?assertEqual(<<"undecodable">>, Reason(<<"not a term">>)),
    ?assertEqual(<<"undecodable">>, Reason(Encode(#{other => 1}, []))),
    %% Within the limits, a plain transcript is recomputed.
    {ok, #{<<"status">> := 200, <<"body">> := #{<<"reason">> :=
            <<"hashpath-not-captured">>}}} =
        verify_hashpath(#{}, #{<<"verification-input-term">> =>
            Encode(Transcript(#{<<"path">> => <<"x">>, <<"n">> => 1}), [])}, #{}).

%% Operator bindings take precedence over request declarations.
execution_bindings_prefer_node_options_test() ->
    Declared = #{
        <<"model-sha256">> => <<"declared-hash">>,
        <<"model-tx">> => <<"declared-tx">>,
        <<"model_sha256">> => <<"ignored">>
    },
    ?assertEqual(
        #{<<"model-sha256">> => <<"operator-hash">>,
            <<"model-tx">> => <<"declared-tx">>,
            <<"inference-profile">> => <<"operator-profile">>},
        add_execution_bindings(#{}, Declared, #{
            <<"model-sha256">> => <<"operator-hash">>,
            <<"inference-profile">> => <<"operator-profile">>
        })),
    ?assertEqual(#{}, add_execution_bindings(#{}, #{}, #{})).

%% Digests use one encoding for objects of any size: compact JSON with the
%% members of every object in ascending byte order of their keys.
digest_is_canonical_for_objects_of_any_size_test() ->
    Large = maps:from_list([{<<"k", (integer_to_binary(I))/binary>>, I}
        || I <- lists:seq(1, 40)]),
    Members = [<<"\"", Key/binary, "\":", (integer_to_binary(Value))/binary>>
        || {Key, Value} <- lists:sort(maps:to_list(Large))],
    Object = <<"{", (iolist_to_binary(lists:join(<<",">>, Members)))/binary, "}">>,
    Expected = <<"{\"a\":[", Object/binary, ",1.0,\"\\u001F/\"],\"b\":",
        Object/binary, ",\"c\":null}">>,
    ?assertEqual(Expected, canonical_json(#{
        <<"b">> => Large,
        <<"a">> => [Large, 1.0, <<16#1f, "/">>],
        c => null
    })),
    ?assertEqual(hb_util:encode(crypto:hash(sha256, Expected)), digest(#{
        <<"b">> => Large,
        <<"a">> => [Large, 1.0, <<16#1f, "/">>],
        c => null
    })),
    %% Small objects encode as `hb_json:encode/1' does.
    Small = #{<<"b">> => 1, <<"a">> => #{<<"d">> => true, <<"c">> => <<"x">>}},
    ?assertEqual(hb_json:encode(Small), canonical_json(Small)).

%% Transcript recorded on the reference deployment on 2026-10-12 by
%% HyperBEAM 28baa3d2 (`ao-core.status=captured'). The HashPath is specific to
%% the pinned HyperBEAM version.
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
    %% A changed request does not reproduce the recorded HashPath.
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

%% A receipt with `ao-core.status=not-captured' records no HashPath.
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
