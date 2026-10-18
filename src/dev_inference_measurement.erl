%%% @doc GPU-aware system measurement for inference nodes.
%%%
%%% `inference_measurement@1.0' composes the node's host measurement
%%% (`measurement@1.0', backed by AMD SEV-SNP on the reference deployment)
%%% with NVIDIA GPU attestation (`sev_gpu@1.0') and the host-observed GPU
%%% inventory (`gpu_inventory@1.0'). One 32-byte binding digest, derived from
%%% the caller's nonce and the inventory digest, is the nonce of the fresh
%%% host measurement and of the GPU attestation report, so both hardware
%%% reports commit to the same request and the same inventory. `verify'
%%% recomputes the digest from the recorded binding and checks it against
%%% both reports.
%%%
%%% Without a host measurement device the result is a node-signed,
%%% host-observed envelope that never claims a hardware measurement.
-module(dev_inference_measurement).
-implements(<<"inference_measurement@1.0">>).
-specification("docs/spec/inference_measurement.md").
-export([info/1, boot/3, fresh/3, verify/3, snapshot/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("kernel/include/file.hrl").

-define(VERSION, <<"1.0">>).
-define(OBSERVATION_TYPE, <<"apus-gpu-system-measurement">>).
-define(BASE_TYPE, <<"lapee-measurement">>).
-define(DEFAULT_INVENTORY_DEVICE, <<"gpu_inventory@1.0">>).
-define(DEFAULT_GPU_TEE_DEVICE, <<"sev_gpu@1.0">>).
-define(DEFAULT_BASE_DEVICE, <<"measurement@1.0">>).
-define(DEFAULT_SEV_GUEST_PATH, <<"/dev/sev-guest">>).
%% Upper bound on the caller nonce, which is echoed in every envelope.
-define(MAX_NONCE_BYTES, 1024).
%% Keys this device adds to a base measurement envelope.
-define(COMPOSITION_KEYS, [<<"cpu-tee">>, <<"gpu-tee">>, <<"apus-gpu-composition">>]).

%% @doc Return the keys this device resolves.
-spec info(map()) -> #{ exports := [binary()] }.
info(_Opts) ->
    #{ exports => [<<"boot">>, <<"fresh">>, <<"verify">>, <<"snapshot">>] }.

%% @doc Compose the node's cached boot measurement with fresh GPU evidence.
-spec boot(
    #{ 'measurement-mode' => binary(), _ => _ },
    #{ nonce => binary(), 'measurement-mode' => binary(), _ => _ },
    map()
) -> {ok, map()} | {error, map()}.
boot(Base, Req, Opts) ->
    compose(boot, Base, Req, Opts).

%% @doc Compose a fresh host measurement and fresh GPU evidence, both bound
%% to the caller's nonce and the GPU inventory.
-spec fresh(
    #{ 'measurement-mode' => binary(), _ => _ },
    #{ nonce => binary(), 'measurement-mode' => binary(), _ => _ },
    map()
) -> {ok, map()} | {error, map()}.
fresh(Base, Req, Opts) ->
    compose(fresh, Base, Req, Opts).

%% @doc Verify an envelope produced by `boot' or `fresh'.
-spec verify(
    #{ _ => _ },
    #{ envelope => _, body => _, _ => _ },
    map()
) -> {ok, map()} | {error, map()}.
verify(_Base, Req, Opts) ->
    case request_envelope(Req, Opts) of
        {ok, Envelope} ->
            case hb_maps:get(<<"type">>, Envelope, undefined, Opts) of
                ?BASE_TYPE -> verify_composed(Envelope, Opts);
                ?OBSERVATION_TYPE -> {ok, verify_observation(Envelope, Opts)};
                _ -> error_response(400, <<"invalid-envelope">>)
            end;
        {error, Code} ->
            error_response(400, Code)
    end.

%% @doc Return the inventory device's runtime GPU snapshot.
-spec snapshot(#{ _ => _ }, #{ _ => _ }, map()) -> {ok, map()} | {error, term()}.
snapshot(_Base, _Req, Opts) ->
    Device = device_option(<<"inference-measurement-inventory-device">>,
        ?DEFAULT_INVENTORY_DEVICE, Opts),
    case resolve(Device, #{ <<"path">> => <<"snapshot">> }, Opts) of
        {ok, Result} ->
            case typed(Result, <<"apus-gpu-runtime-snapshot">>, Opts) of
                {ok, Snapshot} -> {ok, Snapshot};
                error -> error_response(502, <<"invalid-snapshot">>)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%%% ------------------------------------------------------------------
%%% Composition
%%% ------------------------------------------------------------------

compose(Purpose, Base, Req, Opts) ->
    case request_nonce(Req, Opts) of
        {ok, RequestNonce} ->
            Inventory = inventory(Opts),
            Binding = binding(RequestNonce, Inventory),
            case requested_mode(Base, Req, Opts) of
                'observation-only' ->
                    observation(Purpose, Inventory, Binding, Opts, undefined);
                'hook-body' ->
                    base_measurement(Purpose, Inventory, Binding, Opts);
                auto ->
                    case base_available(Opts) of
                        true -> base_measurement(Purpose, Inventory, Binding, Opts);
                        false -> observation(Purpose, Inventory, Binding, Opts, undefined)
                    end
            end;
        {error, Code} ->
            error_response(400, Code)
    end.

%% @doc The caller's nonce, or 32 random bytes (base64url) when absent. A
%% nonce is UTF-8 text because it enters the binding's JSON encoding.
request_nonce(Req, Opts) ->
    case hb_ao:get(<<"nonce">>, Req, undefined, Opts) of
        undefined ->
            {ok, hb_util:encode(crypto:strong_rand_bytes(32))};
        Nonce when is_binary(Nonce), byte_size(Nonce) > 0,
                byte_size(Nonce) =< ?MAX_NONCE_BYTES ->
            case is_text(Nonce) of
                true -> {ok, Nonce};
                false -> {error, <<"invalid-nonce">>}
            end;
        _ ->
            {error, <<"invalid-nonce">>}
    end.

%% @doc The integration mode: the request, then the base message, then the
%% `measurement-mode' node option. Unknown values select `auto'.
requested_mode(Base, Req, Opts) ->
    Mode = first_defined([
        hb_ao:get(<<"measurement-mode">>, Req, undefined, Opts),
        hb_ao:get(<<"measurement-mode">>, Base, undefined, Opts),
        hb_opts:get(<<"measurement-mode">>, undefined, Opts)
    ]),
    case Mode of
        <<"observation-only">> -> 'observation-only';
        'observation-only' -> 'observation-only';
        <<"hook-body">> -> 'hook-body';
        'hook-body' -> 'hook-body';
        _ -> auto
    end.

%% @doc The stable GPU inventory. When the inventory device cannot answer, a
%% report with no devices and the failure in `errors' takes its place.
inventory(Opts) ->
    Device = device_option(<<"inference-measurement-inventory-device">>,
        ?DEFAULT_INVENTORY_DEVICE, Opts),
    case resolve(Device, #{ <<"path">> => <<"report">> }, Opts) of
        {ok, Result} ->
            case typed(Result, <<"apus-gpu-inventory">>, Opts) of
                {ok, #{ <<"inventory-digest">> := Digest } = Inventory} ->
                    case is_text(Digest) of
                        true -> Inventory;
                        false -> unavailable_inventory(<<"invalid-inventory">>)
                    end;
                _ ->
                    unavailable_inventory(<<"invalid-inventory">>)
            end;
        {error, Reason} ->
            unavailable_inventory(reason_text(Reason))
    end.

%% @doc An inventory with no devices, shaped and digested like an empty
%% `gpu_inventory@1.0' report.
unavailable_inventory(Reason) ->
    Topology = #{
        <<"device-count">> => 0,
        <<"pci-bdfs">> => [],
        <<"iommu-groups">> => []
    },
    #{
        <<"type">> => <<"apus-gpu-inventory">>,
        <<"version">> => ?VERSION,
        <<"collected-at-unix">> => erlang:system_time(second),
        <<"provenance">> => #{
            <<"class">> => <<"host-observed">>,
            <<"sources">> => []
        },
        <<"supported">> => false,
        <<"devices">> => [],
        <<"topology">> => Topology,
        <<"inventory-digest">> =>
            hb_util:encode(crypto:hash(sha256,
                hb_json:encode(#{ <<"devices">> => [], <<"topology">> => Topology }))),
        <<"errors">> => [Reason]
    }.

%% @doc The nonce binding: the caller's nonce and the inventory digest.
binding(RequestNonce, Inventory) ->
    #{
        <<"request-nonce">> => RequestNonce,
        <<"gpu-inventory-digest">> => maps:get(<<"inventory-digest">>, Inventory)
    }.

%% @doc SHA-256 of the binding's compact JSON encoding (keys in lexicographic
%% order). The base measurement receives it base64url-encoded and the GPU
%% attestation hex-encoded. Both binding values are UTF-8 text.
binding_digest(Binding) ->
    crypto:hash(sha256, hb_json:encode(Binding)).

%% @doc The binding digest of a recorded `nonce-binding', or `error' when it
%% does not hold two text values.
recorded_digest(#{ <<"request-nonce">> := RequestNonce, <<"gpu-inventory-digest">> := Digest })
        when is_binary(RequestNonce), is_binary(Digest) ->
    case is_text(RequestNonce) andalso is_text(Digest) of
        true ->
            {ok, binding_digest(binding(RequestNonce, #{ <<"inventory-digest">> => Digest }))};
        false ->
            error
    end;
recorded_digest(_) ->
    error.

%% @doc Whether the base measurement device answers `info'.
base_available(Opts) ->
    Device = device_option(<<"inference-measurement-base-device">>, ?DEFAULT_BASE_DEVICE, Opts),
    case resolve(Device, #{ <<"path">> => <<"info">> }, Opts) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% @doc Compose with the base measurement device. A failed or unexpected
%% base response yields an observation envelope that records the failure.
base_measurement(Purpose, Inventory, Binding, Opts) ->
    Device = device_option(<<"inference-measurement-base-device">>, ?DEFAULT_BASE_DEVICE, Opts),
    Request =
        case Purpose of
            fresh ->
                #{
                    <<"path">> => <<"fresh">>,
                    <<"nonce">> => host_nonce(binding_digest(Binding))
                };
            boot ->
                #{ <<"path">> => <<"boot">> }
        end,
    case resolve(Device, Request, Opts) of
        {ok, Response} ->
            case typed(Response, ?BASE_TYPE, Opts) of
                {ok, Envelope} ->
                    {ok, compose_envelope(Purpose, Envelope, Inventory, Binding, Opts)};
                error ->
                    observation(Purpose, Inventory, Binding, Opts,
                        <<"invalid-base-measurement">>)
            end;
        {error, Reason} ->
            observation(Purpose, Inventory, Binding, Opts, reason_text(Reason))
    end.

%% @doc Add the CPU TEE summary, the GPU evidence and the composition record
%% to a base measurement envelope. A fresh host measurement is verified
%% against the binding digest it was requested for, and the binding counts
%% as hardware-bound when the report's evidence carries that digest.
compose_envelope(Purpose, Envelope, Inventory, Binding, Opts) ->
    ExpectedNonce =
        case Purpose of
            fresh -> host_nonce(binding_digest(Binding));
            boot -> undefined
        end,
    HardwareBound =
        ExpectedNonce =/= undefined andalso evidence_nonce(Envelope, Opts) =:= ExpectedNonce,
    Verification = base_verification(Envelope, ExpectedNonce, Opts),
    Evidence = materialize(hb_maps:get(<<"evidence">>, Envelope, #{}, Opts), Opts),
    Subject = materialize(hb_maps:get(<<"body">>, Envelope, #{}, Opts), Opts),
    MeasurementDevice = hb_maps:get(<<"measurement-device">>, Envelope, undefined, Opts),
    Envelope#{
        <<"cpu-tee">> => #{
            <<"type">> => tee_type(MeasurementDevice),
            <<"available">> => is_map(Evidence) andalso map_size(Evidence) > 0,
            <<"report-generated">> =>
                is_map(Evidence) andalso maps:is_key(<<"report-raw">>, Evidence),
            <<"verified">> => verified_flag(Verification, Opts),
            <<"verification">> => Verification,
            <<"report">> => Evidence
        },
        <<"gpu-tee">> => gpu_tee(Binding, Opts),
        <<"apus-gpu-composition">> => #{
            <<"type">> => ?OBSERVATION_TYPE,
            <<"version">> => ?VERSION,
            <<"measurement-integration">> => true,
            <<"integration-mode">> =>
                case Purpose of
                    fresh -> <<"measurement-nonce">>;
                    boot -> <<"boot-measurement">>
                end,
            <<"nonce-binding-hardware-bound">> => HardwareBound,
            <<"base-measurement-id">> => message_id(Envelope, signed, Opts),
            <<"gpu-inventory-digest">> => maps:get(<<"inventory-digest">>, Inventory),
            <<"nonce-binding">> => Binding,
            <<"subject-id">> => message_id(Subject, none, Opts),
            <<"provenance-class">> => <<"host-measured-subject">>
        }
    }.

tee_type(<<"snp@1.0">>) -> <<"amd-sev-snp">>;
tee_type(Device) when is_binary(Device) -> Device;
tee_type(_) -> <<"unknown">>.

%% @doc The base device's verdict on its own envelope. With a nonce, the base
%% device also checks that its hardware report commits to that nonce.
base_verification(Envelope, ExpectedNonce, Opts) ->
    Device = device_option(<<"inference-measurement-base-device">>, ?DEFAULT_BASE_DEVICE, Opts),
    Request = with_optional(
        #{ <<"path">> => <<"verify">>, <<"envelope">> => Envelope },
        <<"nonce">>,
        ExpectedNonce
    ),
    case resolve(Device, Request, Opts) of
        {ok, Result} -> unwrap_body(Result, Opts);
        {error, Reason} -> #{ <<"verified">> => false, <<"error">> => reason_text(Reason) }
    end.

%% @doc The nonce a base measurement receives for a binding digest.
host_nonce(Digest) ->
    hb_util:encode(Digest).

%% @doc A node-signed envelope of host-observed facts. It never claims a
%% hardware measurement.
observation(Purpose, Inventory, Binding, Opts, Failure) ->
    Body = with_optional(
        #{
            <<"type">> => ?OBSERVATION_TYPE,
            <<"version">> => ?VERSION,
            <<"purpose">> => atom_to_binary(Purpose, utf8),
            <<"issued-at-unix">> => erlang:system_time(second),
            <<"measurement-integration">> => false,
            <<"integration-mode">> => <<"observation-only">>,
            <<"provenance-class">> => <<"host-observed">>,
            <<"cpu-tee">> => cpu_tee_observation(Opts),
            <<"gpu-tee">> => gpu_tee(Binding, Opts),
            <<"gpu-inventory">> => Inventory,
            <<"gpu-inventory-digest">> => maps:get(<<"inventory-digest">>, Inventory),
            <<"nonce-binding">> => Binding
        },
        <<"failure">>,
        Failure
    ),
    Signed =
        try hb_message:commit(Body, Opts)
        catch _:_ -> Body
        end,
    {ok, Signed}.

%% @doc Whether the SEV-SNP guest device exists. A present device is not a
%% verified report, so `verified' and `report-generated' stay false.
cpu_tee_observation(Opts) ->
    Path = path_option(<<"inference-measurement-sev-guest-path">>, ?DEFAULT_SEV_GUEST_PATH, Opts),
    case file:read_file_info(Path) of
        {ok, #file_info{ type = Type }} when Type =:= device; Type =:= regular ->
            #{
                <<"type">> => <<"amd-sev-snp">>,
                <<"available">> => true,
                <<"verified">> => false,
                <<"report-generated">> => false,
                <<"device">> => Path,
                <<"reason">> => <<"SNP guest device present; this observation carries no SNP report">>
            };
        _ ->
            #{
                <<"type">> => <<"amd-sev-snp">>,
                <<"available">> => false,
                <<"verified">> => false,
                <<"report-generated">> => false,
                <<"reason">> => <<"SNP guest device not present">>
            }
    end.

%% @doc Fresh NVIDIA GPU evidence whose nonce is the hex binding digest.
gpu_tee(Binding, Opts) ->
    Nonce = hb_util:to_hex(binding_digest(Binding)),
    Device = device_option(<<"inference-measurement-gpu-tee-device">>,
        ?DEFAULT_GPU_TEE_DEVICE, Opts),
    Base = with_optional(#{ <<"nonce">> => Nonce }, <<"device">>, device_name(Device)),
    Request = #{ <<"path">> => <<"generate">>, <<"nonce">> => Nonce },
    case resolve(Device, Request, Opts) of
        {ok, Result} ->
            case gpu_report(Result, Opts) of
                {ok, #{ <<"nonce">> := Echoed } = Report} when Echoed =:= Nonce ->
                    maps:merge(Report, Base#{ <<"available">> => true });
                {ok, _} ->
                    gpu_unavailable(Base, <<"nonce-mismatch">>);
                error ->
                    gpu_unavailable(Base, <<"invalid-response">>)
            end;
        {error, Reason} ->
            gpu_unavailable(Base, reason_text(Reason))
    end.

gpu_unavailable(Base, Reason) ->
    Base#{
        <<"available">> => false,
        <<"verified">> => false,
        <<"reason">> => Reason
    }.

%% @doc Read a `sev_gpu@1.0' result: a JSON binary, or the same object as a
%% message, directly or under `body'.
gpu_report(Bin, Opts) when is_binary(Bin) ->
    try hb_json:decode(Bin) of
        Map when is_map(Map) -> gpu_report(Map, Opts);
        _ -> error
    catch
        _:_ -> error
    end;
gpu_report(Map, Opts) when is_map(Map) ->
    case maps:is_key(<<"verified">>, Map) andalso maps:is_key(<<"nonce">>, Map) of
        true ->
            {ok, maps:with(
                [<<"nonce">>, <<"verified">>, <<"evidences">>, <<"claims">>, <<"eat">>],
                Map
            )};
        false ->
            case hb_maps:get(<<"body">>, Map, undefined, Opts) of
                undefined -> error;
                Body -> gpu_report(materialize(Body, Opts), Opts)
            end
    end;
gpu_report(_, _Opts) ->
    error.

%%% ------------------------------------------------------------------
%%% Verification
%%% ------------------------------------------------------------------

%% @doc The envelope from `envelope', or from `body': a message, or its
%% `json@1.0' encoding (the form `accept: application/json' returns), which
%% keeps the commitments verifiable.
request_envelope(Req, Opts) ->
    case first_defined([
        hb_ao:get(<<"envelope">>, Req, undefined, Opts),
        hb_ao:get(<<"body">>, Req, undefined, Opts)
    ]) of
        undefined -> {error, <<"envelope-required">>};
        Bin when is_binary(Bin) ->
            try hb_message:convert(Bin, <<"structured@1.0">>, <<"json@1.0">>, Opts) of
                Map when is_map(Map) -> {ok, materialize(Map, Opts)};
                _ -> {error, <<"invalid-envelope">>}
            catch
                _:_ -> {error, <<"invalid-envelope">>}
            end;
        Map when is_map(Map) -> {ok, materialize(Map, Opts)};
        _ -> {error, <<"invalid-envelope">>}
    end.

%% @doc Verify a composed envelope. The base device verifies the base
%% measurement without the keys this device adds. For a `measurement-nonce'
%% composition the binding digest is recomputed from the recorded binding:
%% the base device must verify its report against that digest and the
%% report's evidence must carry it, so the binding is anchored in the
%% hardware report. A `boot-measurement' composition binds nothing into
%% the report; its `verified' covers the base measurement alone.
verify_composed(Envelope, Opts) ->
    Base = maps:without(?COMPOSITION_KEYS, Envelope),
    Composition = as_map(hb_maps:get(<<"apus-gpu-composition">>, Envelope, #{}, Opts), Opts),
    GpuTee = as_map(hb_maps:get(<<"gpu-tee">>, Envelope, #{}, Opts), Opts),
    BindingVerified = binding_verified(Composition, GpuTee, Opts),
    Anchored =
        hb_maps:get(<<"integration-mode">>, Composition, undefined, Opts)
            =:= <<"measurement-nonce">>,
    ExpectedNonce =
        case {Anchored, recorded_digest(as_map(
                hb_maps:get(<<"nonce-binding">>, Composition, undefined, Opts), Opts))} of
            {true, {ok, Digest}} -> host_nonce(Digest);
            _ -> undefined
        end,
    BaseVerification = base_verification(Base, ExpectedNonce, Opts),
    BaseVerified = verified_flag(BaseVerification, Opts),
    HardwareBound =
        ExpectedNonce =/= undefined
            andalso BaseVerified
            andalso BindingVerified
            andalso evidence_nonce(Base, Opts) =:= ExpectedNonce,
    {ok, #{
        <<"verified">> =>
            case Anchored of
                true -> HardwareBound;
                false -> BaseVerified
            end,
        <<"base-verification">> => BaseVerification,
        <<"nonce-binding-verified">> => BindingVerified,
        <<"nonce-binding-hardware-bound">> => HardwareBound,
        <<"gpu-tee-verified">> => gpu_evidence_verified(GpuTee, Opts),
        <<"provenance-class">> => <<"host-measured-subject">>
    }}.

%% @doc The nonce recorded in a base measurement's hardware evidence.
evidence_nonce(Envelope, Opts) ->
    case materialize(hb_maps:get(<<"evidence">>, Envelope, #{}, Opts), Opts) of
        Evidence when is_map(Evidence) ->
            hb_maps:get(<<"nonce">>, Evidence, undefined, Opts);
        _ ->
            undefined
    end.

%% @doc Verify an observation envelope: the node's signature and the nonce
%% binding of its GPU evidence.
verify_observation(Envelope, Opts) ->
    Signers = signers(Envelope, Opts),
    SignatureVerified =
        Signers =/= [] andalso
            (try hb_message:verify(Envelope, signers, Opts) catch _:_ -> false end) =:= true,
    GpuTee = hb_maps:get(<<"gpu-tee">>, Envelope, #{}, Opts),
    BindingVerified = binding_verified(Envelope, GpuTee, Opts),
    #{
        <<"verified">> => SignatureVerified andalso BindingVerified,
        <<"signature-verified">> => SignatureVerified,
        <<"signers">> => Signers,
        <<"nonce-binding-verified">> => BindingVerified,
        <<"gpu-tee-verified">> => gpu_evidence_verified(GpuTee, Opts),
        <<"observation-id">> => message_id(Envelope, signed, Opts),
        <<"provenance-class">> => <<"host-observed">>
    }.

%% @doc `Holder' carries `nonce-binding' and `gpu-inventory-digest'. The
%% binding must name that digest, and available GPU evidence must carry the
%% hex binding digest as its nonce.
binding_verified(Holder, GpuTee, Opts) when is_map(Holder), is_map(GpuTee) ->
    Binding = as_map(hb_maps:get(<<"nonce-binding">>, Holder, undefined, Opts), Opts),
    case recorded_digest(Binding) of
        {ok, BindingDigest} ->
            Expected = hb_util:to_hex(BindingDigest),
            maps:get(<<"gpu-inventory-digest">>, Binding) =:=
                hb_maps:get(<<"gpu-inventory-digest">>, Holder, undefined, Opts)
                andalso
                case hb_maps:get(<<"available">>, GpuTee, false, Opts) of
                    true ->
                        case hb_maps:get(<<"nonce">>, GpuTee, undefined, Opts) of
                            Nonce when is_binary(Nonce) -> hb_util:to_lower(Nonce) =:= Expected;
                            _ -> false
                        end;
                    _ ->
                        true
                end;
        error ->
            false
    end;
binding_verified(_Holder, _GpuTee, _Opts) ->
    false.

%% @doc Re-verify recorded GPU evidence with the GPU TEE device.
gpu_evidence_verified(GpuTee, Opts) when is_map(GpuTee) ->
    case {
        hb_maps:get(<<"available">>, GpuTee, false, Opts),
        hb_maps:get(<<"evidences">>, GpuTee, [], Opts),
        hb_maps:get(<<"nonce">>, GpuTee, undefined, Opts)
    } of
        {true, [_ | _] = Evidences, Nonce} when is_binary(Nonce) ->
            Device = device_option(<<"inference-measurement-gpu-tee-device">>,
                ?DEFAULT_GPU_TEE_DEVICE, Opts),
            try hb_json:encode(Evidences) of
                Body ->
                    Request = #{
                        <<"path">> => <<"verify">>,
                        <<"body">> => Body,
                        <<"nonce">> => Nonce
                    },
                    resolve(Device, Request, Opts) =:= {ok, <<"true">>}
            catch
                _:_ -> false
            end;
        _ ->
            false
    end;
gpu_evidence_verified(_GpuTee, _Opts) ->
    false.

signers(Envelope, Opts) ->
    try hb_message:signers(Envelope, Opts) of
        Signers when is_list(Signers) -> Signers;
        _ -> []
    catch
        _:_ -> []
    end.

%%% ------------------------------------------------------------------
%%% Helpers
%%% ------------------------------------------------------------------

%% @doc Resolve a key on a dependency device. Results are never served from
%% or written to the cache: every call observes the host afresh.
resolve(Device, Request, Opts) ->
    LocalOpts = Opts#{ <<"cache-control">> => [<<"no-cache">>, <<"no-store">>] },
    try hb_ao:resolve(#{ <<"device">> => Device }, Request, LocalOpts) of
        {ok, Result} -> {ok, materialize(Result, Opts)};
        {error, Reason} -> {error, Reason};
        Other -> {error, Other}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% @doc A result of the given `type', returned bare or under `body'.
typed(Result, Type, Opts) when is_map(Result) ->
    case hb_maps:get(<<"type">>, Result, undefined, Opts) of
        Type -> {ok, Result};
        _ ->
            case hb_maps:get(<<"body">>, Result, undefined, Opts) of
                Body when is_map(Body) ->
                    Loaded = materialize(Body, Opts),
                    case hb_maps:get(<<"type">>, Loaded, undefined, Opts) of
                        Type -> {ok, Loaded};
                        _ -> error
                    end;
                _ -> error
            end
    end;
typed(_Result, _Type, _Opts) ->
    error.

unwrap_body(Result, Opts) when is_map(Result) ->
    case hb_maps:get(<<"body">>, Result, undefined, Opts) of
        Body when is_map(Body) -> materialize(Body, Opts);
        _ -> Result
    end;
unwrap_body(Result, _Opts) ->
    #{ <<"result">> => Result }.

%% @doc A map value, loaded from the cache when it is a link; anything else
%% reads as an empty map.
as_map(Value, Opts) ->
    case materialize(Value, Opts) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.

is_text(Value) when is_binary(Value) ->
    unicode:characters_to_binary(Value) =:= Value;
is_text(_) ->
    false.

verified_flag(Verification, Opts) when is_map(Verification) ->
    hb_maps:get(<<"verified">>, Verification, false, Opts) =:= true;
verified_flag(_, _Opts) ->
    false.

materialize(Value, Opts) ->
    try hb_cache:ensure_all_loaded(Value, Opts)
    catch _:_ -> Value
    end.

message_id(Msg, Committers, Opts) when is_map(Msg) ->
    try hb_message:id(Msg, Committers, Opts)
    catch _:_ -> undefined
    end;
message_id(_Msg, _Committers, _Opts) ->
    undefined.

%% @doc A dependency device from a node option: a device name, or (in
%% tests) a device given as a map of functions.
device_option(Key, Default, Opts) ->
    case hb_opts:get(Key, Default, Opts) of
        Device when is_binary(Device); is_map(Device) -> Device;
        _ -> Default
    end.

device_name(Device) when is_binary(Device) -> Device;
device_name(_) -> undefined.

path_option(Key, Default, Opts) ->
    case hb_opts:get(Key, Default, Opts) of
        Path when is_binary(Path) -> Path;
        Path when is_list(Path) -> unicode:characters_to_binary(Path);
        _ -> Default
    end.

with_optional(Map, _Key, undefined) -> Map;
with_optional(Map, Key, Value) -> Map#{ Key => Value }.

%% @doc A short text for a failure recorded in an envelope.
reason_text(Reason) when is_binary(Reason) ->
    binary:part(Reason, 0, min(byte_size(Reason), 512));
reason_text(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
reason_text({Tag, Detail}) when is_atom(Tag), is_binary(Detail) ->
    reason_text(<<(atom_to_binary(Tag, utf8))/binary, ": ", Detail/binary>>);
reason_text({Tag, _}) when is_atom(Tag) ->
    atom_to_binary(Tag, utf8);
reason_text(#{ <<"body">> := #{ <<"error">> := Error } }) when is_binary(Error) ->
    Error;
reason_text(#{ <<"error">> := Error }) when is_binary(Error) ->
    Error;
reason_text(_) ->
    <<"unavailable">>.

error_response(Status, Code) ->
    {error, #{ <<"status">> => Status, <<"body">> => #{ <<"error">> => Code } }}.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([not_found | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value.

%%% ------------------------------------------------------------------
%%% Tests
%%% ------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_DIGEST, <<"OQ6jjieUQbTtI-MX-ai4cEGhp-ZwEo9lm1fYxyB51uk">>).

test_inventory() ->
    #{
        <<"type">> => <<"apus-gpu-inventory">>,
        <<"version">> => ?VERSION,
        <<"supported">> => true,
        <<"devices">> => [#{ <<"pci-bdf">> => <<"0000:01:00.0">> }],
        <<"inventory-digest">> => ?TEST_DIGEST,
        <<"errors">> => []
    }.

%% A stand-in GPU TEE device that attests whatever nonce it is given.
gpu_tee_stub() ->
    #{
        generate => fun(_Base, Req, _Opts) ->
            Nonce = maps:get(<<"nonce">>, Req),
            {ok, hb_json:encode(#{
                <<"nonce">> => Nonce,
                <<"verified">> => true,
                <<"evidences">> => [#{ <<"nonce">> => Nonce }],
                <<"claims">> => [#{ <<"eat_nonce">> => Nonce }],
                <<"eat">> => [[<<"JWT">>, <<"token">>]]
            })}
        end,
        verify => fun(_Base, Req, _Opts) ->
            {ok, atom_to_binary(maps:is_key(<<"nonce">>, Req), utf8)}
        end
    }.

inventory_stub(Result) ->
    #{
        report => fun(_, _, _) -> {ok, Result} end,
        snapshot => fun(_, _, _) ->
            {ok, #{ <<"type">> => <<"apus-gpu-runtime-snapshot">>, <<"devices">> => [] }}
        end
    }.

%% A stand-in base measurement device that records the nonce it measures.
%% Like `snp@1.0', its `verify' checks the report nonce when it is given one.
base_stub() ->
    #{
        info => fun(_, _, _) -> {ok, #{ <<"version">> => <<"1">> }} end,
        fresh => fun(_, Req, _) ->
            {ok, #{
                <<"type">> => ?BASE_TYPE,
                <<"measurement-device">> => <<"snp@1.0">>,
                <<"body">> => #{ <<"system">> => #{ <<"os">> => <<"linux">> } },
                <<"evidence">> => #{
                    <<"type">> => <<"lapee-snp-evidence">>,
                    <<"report-raw">> => <<"report">>,
                    <<"nonce">> => maps:get(<<"nonce">>, Req)
                }
            }}
        end,
        verify => fun(_, Req, _) ->
            Envelope = maps:get(<<"envelope">>, Req),
            Clean = not lists:any(fun(K) -> maps:is_key(K, Envelope) end, ?COMPOSITION_KEYS),
            NonceMatches =
                case maps:get(<<"nonce">>, Req, undefined) of
                    undefined -> true;
                    Nonce ->
                        Nonce =:= maps:get(<<"nonce">>, maps:get(<<"evidence">>, Envelope))
                end,
            {ok, #{
                <<"status">> => 200,
                <<"body">> => #{ <<"verified">> => Clean andalso NonceMatches }
            }}
        end
    }.

stub_opts(Extra) ->
    maps:merge(
        #{
            <<"priv-wallet">> => ar_wallet:new(),
            <<"inference-measurement-inventory-device">> => inventory_stub(test_inventory()),
            <<"inference-measurement-gpu-tee-device">> => gpu_tee_stub(),
            <<"inference-measurement-base-device">> => #{},
            <<"inference-measurement-sev-guest-path">> => <<"/nonexistent/sev-guest">>
        },
        Extra
    ).

mode_defaults_to_auto_test() ->
    ?assertEqual(auto, requested_mode(#{}, #{}, #{})).

mode_can_be_forced_test() ->
    ?assertEqual('observation-only',
        requested_mode(#{}, #{ <<"measurement-mode">> => <<"observation-only">> }, #{})),
    ?assertEqual('hook-body',
        requested_mode(#{}, #{}, #{ <<"measurement-mode">> => <<"hook-body">> })),
    ?assertEqual(auto,
        requested_mode(#{}, #{ <<"measurement-mode">> => <<"other">> }, #{})).

unavailable_inventory_stays_observable_test() ->
    Inventory = unavailable_inventory(<<"gpu_inventory@1.0 unavailable">>),
    ?assertEqual(false, maps:get(<<"supported">>, Inventory)),
    ?assertEqual([], maps:get(<<"devices">>, Inventory)),
    ?assertEqual([<<"gpu_inventory@1.0 unavailable">>], maps:get(<<"errors">>, Inventory)),
    ?assert(is_binary(maps:get(<<"inventory-digest">>, Inventory))).

binding_digest_is_canonical_test() ->
    Binding = binding(<<"request">>, #{ <<"inventory-digest">> => ?TEST_DIGEST }),
    Canonical = <<"{\"gpu-inventory-digest\":\"", ?TEST_DIGEST/binary,
        "\",\"request-nonce\":\"request\"}">>,
    ?assertEqual(crypto:hash(sha256, Canonical), binding_digest(Binding)).

nonce_is_validated_test() ->
    ?assertMatch({ok, _}, request_nonce(#{}, #{})),
    ?assertEqual({ok, <<"abc">>}, request_nonce(#{ <<"nonce">> => <<"abc">> }, #{})),
    ?assertEqual({error, <<"invalid-nonce">>},
        request_nonce(#{ <<"nonce">> => binary:copy(<<"a">>, 1025) }, #{})),
    ?assertMatch({error, #{ <<"status">> := 400 }},
        fresh(#{}, #{ <<"nonce">> => <<>> }, stub_opts(#{}))),
    %% The nonce enters a JSON encoding, so it must be UTF-8 text.
    ?assertEqual({error, <<"invalid-nonce">>},
        request_nonce(#{ <<"nonce">> => <<255, 0>> }, #{})),
    ?assertMatch({error, #{ <<"status">> := 400, <<"body">> := #{ <<"error">> := <<"invalid-nonce">> } }},
        boot(#{}, #{ <<"nonce">> => <<"caf", 233>> }, stub_opts(#{}))),
    ?assertEqual({ok, <<"caf", 195, 169>>},
        request_nonce(#{ <<"nonce">> => <<"caf", 195, 169>> }, #{})).

observation_binds_gpu_evidence_test() ->
    Opts = stub_opts(#{}),
    {ok, Envelope} = fresh(#{}, #{ <<"nonce">> => <<"request-1">> }, Opts),
    Binding = #{
        <<"request-nonce">> => <<"request-1">>,
        <<"gpu-inventory-digest">> => ?TEST_DIGEST
    },
    Nonce = hb_util:to_hex(binding_digest(Binding)),
    ?assertMatch(
        #{
            <<"type">> := ?OBSERVATION_TYPE,
            <<"purpose">> := <<"fresh">>,
            <<"measurement-integration">> := false,
            <<"provenance-class">> := <<"host-observed">>,
            <<"gpu-inventory-digest">> := ?TEST_DIGEST,
            <<"nonce-binding">> := Binding,
            <<"gpu-tee">> := #{
                <<"available">> := true,
                <<"verified">> := true,
                <<"nonce">> := Nonce
            },
            <<"cpu-tee">> := #{ <<"available">> := false }
        },
        Envelope
    ),
    ?assertNot(maps:is_key(<<"failure">>, Envelope)),
    ?assertNot(maps:is_key(<<"status">>, Envelope)),
    ?assertNot(maps:is_key(<<"body">>, Envelope)),
    ?assertNotEqual([], hb_message:signers(Envelope, Opts)).

inventory_and_gpu_shapes_are_tolerated_test() ->
    Wrapped = #{ <<"status">> => 200, <<"body">> => test_inventory() },
    GpuMap = #{
        generate => fun(_, Req, _) ->
            Nonce = maps:get(<<"nonce">>, Req),
            {ok, #{ <<"status">> => 200, <<"body">> => #{
                <<"nonce">> => Nonce, <<"verified">> => false,
                <<"evidences">> => [], <<"claims">> => [], <<"eat">> => null
            }}}
        end
    },
    Opts = stub_opts(#{
        <<"inference-measurement-inventory-device">> => inventory_stub(Wrapped),
        <<"inference-measurement-gpu-tee-device">> => GpuMap
    }),
    {ok, Envelope} = fresh(#{}, #{ <<"nonce">> => <<"n">> }, Opts),
    ?assertEqual(?TEST_DIGEST, maps:get(<<"gpu-inventory-digest">>, Envelope)),
    ?assertMatch(#{ <<"available">> := true, <<"verified">> := false },
        maps:get(<<"gpu-tee">>, Envelope)).

gpu_nonce_mismatch_is_unavailable_test() ->
    Stale = #{
        generate => fun(_, _, _) ->
            {ok, hb_json:encode(#{ <<"nonce">> => binary:copy(<<"00">>, 32),
                <<"verified">> => true })}
        end
    },
    Opts = stub_opts(#{ <<"inference-measurement-gpu-tee-device">> => Stale }),
    {ok, Envelope} = fresh(#{}, #{}, Opts),
    ?assertMatch(
        #{ <<"available">> := false, <<"verified">> := false, <<"reason">> := <<"nonce-mismatch">> },
        maps:get(<<"gpu-tee">>, Envelope)
    ).

missing_dependencies_degrade_to_observation_test() ->
    Opts = stub_opts(#{
        <<"inference-measurement-inventory-device">> => #{},
        <<"inference-measurement-gpu-tee-device">> => #{}
    }),
    {ok, Envelope} = fresh(#{}, #{}, Opts),
    ?assertMatch(
        #{
            <<"type">> := ?OBSERVATION_TYPE,
            <<"gpu-inventory">> := #{ <<"supported">> := false, <<"errors">> := [_] },
            <<"gpu-tee">> := #{ <<"available">> := false }
        },
        Envelope
    ).

sev_guest_path_is_a_node_option_test() ->
    Path = filename:absname("rebar.config"),
    Present = cpu_tee_observation(#{
        <<"inference-measurement-sev-guest-path">> => hb_util:bin(Path)
    }),
    ?assertMatch(#{ <<"available">> := true, <<"verified">> := false }, Present),
    ?assertEqual(hb_util:bin(Path), maps:get(<<"device">>, Present)),
    ?assertMatch(#{ <<"available">> := false },
        cpu_tee_observation(#{
            <<"inference-measurement-sev-guest-path">> => <<"/nonexistent/sev-guest">>
        })).

composition_binds_both_reports_test() ->
    Opts = stub_opts(#{ <<"inference-measurement-base-device">> => base_stub() }),
    {ok, Envelope} = fresh(#{}, #{ <<"nonce">> => <<"request-2">> }, Opts),
    Binding = #{
        <<"request-nonce">> => <<"request-2">>,
        <<"gpu-inventory-digest">> => ?TEST_DIGEST
    },
    Digest = binding_digest(Binding),
    ?assertMatch(
        #{
            <<"type">> := ?BASE_TYPE,
            <<"evidence">> := #{ <<"nonce">> := _ },
            <<"cpu-tee">> := #{
                <<"type">> := <<"amd-sev-snp">>,
                <<"available">> := true,
                <<"report-generated">> := true,
                <<"verified">> := true
            },
            <<"apus-gpu-composition">> := #{
                <<"measurement-integration">> := true,
                <<"integration-mode">> := <<"measurement-nonce">>,
                <<"nonce-binding-hardware-bound">> := true,
                <<"nonce-binding">> := Binding,
                <<"provenance-class">> := <<"host-measured-subject">>
            }
        },
        Envelope
    ),
    %% Both hardware reports commit to the same 32-byte digest.
    ?assertEqual(hb_util:encode(Digest),
        maps:get(<<"nonce">>, maps:get(<<"evidence">>, Envelope))),
    ?assertEqual(hb_util:to_hex(Digest),
        maps:get(<<"nonce">>, maps:get(<<"gpu-tee">>, Envelope))),
    ?assertMatch(
        {ok, #{
            <<"verified">> := true,
            <<"nonce-binding-verified">> := true,
            <<"nonce-binding-hardware-bound">> := true,
            <<"gpu-tee-verified">> := true
        }},
        verify(#{}, #{ <<"envelope">> => Envelope }, Opts)
    ).

%% A genuine base measurement taken for another nonce, with a composition
%% record and GPU section attached by someone else.
forged_composition(Mode) ->
    Fresh = maps:get(fresh, base_stub()),
    {ok, Genuine} = Fresh(#{}, #{ <<"nonce">> => hb_util:encode(crypto:strong_rand_bytes(32)) }, #{}),
    Genuine#{
        <<"gpu-tee">> => #{ <<"available">> => false, <<"verified">> => false },
        <<"apus-gpu-composition">> => #{
            <<"type">> => ?OBSERVATION_TYPE,
            <<"integration-mode">> => Mode,
            <<"gpu-inventory-digest">> => ?TEST_DIGEST,
            <<"nonce-binding">> => #{
                <<"request-nonce">> => <<"forged">>,
                <<"gpu-inventory-digest">> => ?TEST_DIGEST
            }
        }
    }.

forged_composition_is_not_verified_test() ->
    Opts = stub_opts(#{ <<"inference-measurement-base-device">> => base_stub() }),
    %% The recorded binding is self-consistent, but the hardware report does
    %% not commit to its digest.
    ?assertMatch(
        {ok, #{
            <<"verified">> := false,
            <<"nonce-binding-verified">> := true,
            <<"nonce-binding-hardware-bound">> := false,
            <<"base-verification">> := #{ <<"verified">> := false }
        }},
        verify(#{}, #{ <<"envelope">> => forged_composition(<<"measurement-nonce">>) }, Opts)
    ),
    %% A base device that ignores the nonce does not change the outcome: the
    %% report's evidence must carry the digest too.
    Lenient = (base_stub())#{
        verify => fun(_, _, _) -> {ok, #{ <<"verified">> => true }} end
    },
    LenientOpts = stub_opts(#{ <<"inference-measurement-base-device">> => Lenient }),
    ?assertMatch(
        {ok, #{ <<"verified">> := false, <<"nonce-binding-hardware-bound">> := false }},
        verify(#{}, #{ <<"envelope">> => forged_composition(<<"measurement-nonce">>) },
            LenientOpts)
    ),
    %% Relabelled as a boot composition, the envelope verifies as its base
    %% measurement only, and the binding is reported as not hardware-bound.
    ?assertMatch(
        {ok, #{ <<"verified">> := true, <<"nonce-binding-hardware-bound">> := false }},
        verify(#{}, #{ <<"envelope">> => forged_composition(<<"boot-measurement">>) }, Opts)
    ).

composed_binding_tampering_is_detected_test() ->
    Opts = stub_opts(#{ <<"inference-measurement-base-device">> => base_stub() }),
    {ok, Envelope} = fresh(#{}, #{ <<"nonce">> => <<"request-3">> }, Opts),
    GpuTee = maps:get(<<"gpu-tee">>, Envelope),
    Tampered = Envelope#{
        <<"gpu-tee">> => GpuTee#{ <<"nonce">> => binary:copy(<<"ab">>, 32) }
    },
    ?assertMatch({ok, #{ <<"verified">> := false, <<"nonce-binding-verified">> := false }},
        verify(#{}, #{ <<"envelope">> => Tampered }, Opts)).

boot_uses_the_cached_base_measurement_test() ->
    Base = (base_stub())#{
        boot => fun(_, Req, _) ->
            {ok, #{
                <<"type">> => ?BASE_TYPE,
                <<"measurement-device">> => <<"snp@1.0">>,
                <<"body">> => #{},
                <<"evidence">> => #{ <<"nonce">> => maps:get(<<"nonce">>, Req, none) }
            }}
        end
    },
    Opts = stub_opts(#{ <<"inference-measurement-base-device">> => Base }),
    {ok, Envelope} = boot(#{}, #{}, Opts),
    ?assertEqual(none, maps:get(<<"nonce">>, maps:get(<<"evidence">>, Envelope))),
    ?assertMatch(
        #{
            <<"integration-mode">> := <<"boot-measurement">>,
            <<"nonce-binding-hardware-bound">> := false
        },
        maps:get(<<"apus-gpu-composition">>, Envelope)
    ),
    ?assertMatch(
        {ok, #{
            <<"verified">> := true,
            <<"nonce-binding-verified">> := true,
            <<"nonce-binding-hardware-bound">> := false
        }},
        verify(#{}, #{ <<"envelope">> => Envelope }, Opts)
    ).

observation_verification_test() ->
    Opts = stub_opts(#{}),
    {ok, Envelope} = fresh(#{}, #{ <<"nonce">> => <<"request-4">> }, Opts),
    {ok, Result} = verify(#{}, #{ <<"envelope">> => Envelope }, Opts),
    ?assertMatch(
        #{
            <<"verified">> := true,
            <<"signature-verified">> := true,
            <<"nonce-binding-verified">> := true,
            <<"gpu-tee-verified">> := true,
            <<"provenance-class">> := <<"host-observed">>
        },
        Result
    ),
    Tampered = Envelope#{ <<"gpu-inventory-digest">> => <<"other">> },
    ?assertMatch({ok, #{ <<"verified">> := false, <<"signature-verified">> := false }},
        verify(#{}, #{ <<"envelope">> => Tampered }, Opts)),
    Unsigned = maps:remove(<<"commitments">>, Envelope),
    ?assertMatch({ok, #{ <<"verified">> := false, <<"signers">> := [] }},
        verify(#{}, #{ <<"envelope">> => Unsigned }, Opts)),
    %% The JSON form a client receives verifies when posted back as `body'.
    JSON = hb_message:convert(Envelope, <<"json@1.0">>, Opts),
    ?assertMatch({ok, #{ <<"verified">> := true, <<"signature-verified">> := true }},
        verify(#{}, #{ <<"body">> => JSON }, Opts)).

verify_rejects_unknown_input_test() ->
    ?assertMatch({error, #{ <<"status">> := 400 }}, verify(#{}, #{}, #{})),
    ?assertMatch({error, #{ <<"status">> := 400 }},
        verify(#{}, #{ <<"body">> => <<"not json">> }, #{})),
    ?assertMatch({error, #{ <<"status">> := 400 }},
        verify(#{}, #{ <<"envelope">> => #{ <<"type">> => <<"other">> } }, #{})).

snapshot_returns_the_inventory_snapshot_test() ->
    ?assertMatch({ok, #{ <<"type">> := <<"apus-gpu-runtime-snapshot">> }},
        snapshot(#{}, #{}, stub_opts(#{}))).

-endif.
