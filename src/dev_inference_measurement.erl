%%% @doc External composition adapter for GPU-aware system measurement.
%%%
%%% When the host exposes `measurement@1.0`, this device preserves its measured system/node subject and binds the GPU
%%% inventory digest into the nonce of a fresh hardware measurement.
%%% On stock HyperBEAM it returns an explicitly lower-trust observation.
-module(dev_inference_measurement).
-implements(<<"inference_measurement@1.0">>).
-export([info/1, boot/3, fresh/3, verify/3, snapshot/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).

%% @doc Return the public device description.
info(_Opts) ->
    #{
        exports => [<<"boot">>, <<"fresh">>, <<"verify">>, <<"snapshot">>],
        description => <<"GPU-aware measurement composition adapter">>,
        version => ?VERSION
    }.

%% @doc Create or return the cached GPU-aware boot measurement.
boot(Base, Req, Opts) -> compose(boot, Base, Req, Opts).

%% @doc Create a fresh GPU-aware measurement for the supplied nonce.
fresh(Base, Req, Opts) -> compose(fresh, Base, Req, Opts).

%% @doc Verify a base measurement or an observation-only envelope.
verify(_Base, Req, Opts) ->
    Envelope = first_defined([
        hb_ao:get(<<"envelope">>, Req, undefined, Opts),
        hb_ao:get(<<"body">>, Req, undefined, Opts),
        Req
    ]),
    case base_measurement_info(Opts) of
        {ok, _Info} ->
            hb_ao:resolve(
                #{<<"device">> => <<"measurement@1.0">>},
                #{<<"path">> => <<"verify">>, <<"envelope">> => Envelope},
                Opts
            );
        {error, _} -> verify_observation(Envelope, Opts)
    end.

%% @doc Return the lower-trust runtime GPU snapshot.
snapshot(Base, Req, Opts) ->
    hb_ao:resolve(
        #{<<"device">> => <<"gpu_inventory@1.0">>},
        #{<<"path">> => <<"snapshot">>,
          <<"gpu-inventory-root">> => inventory_root(Base, Req, Opts)},
        Opts
    ).

%% @doc Compose the inventory with the existing measurement protocol.
compose(Purpose, Base, Req, Opts) ->
    Root = inventory_root(Base, Req, Opts),
    case inventory(Root, Opts) of
        {ok, Inventory} ->
            case requested_mode(Base, Req, Opts) of
                'observation-only' -> observation(Purpose, Inventory, Opts);
                'hook-body' -> base_measurement(Purpose, Inventory, Req, Opts);
                auto ->
                    case base_measurement_info(Opts) of
                        {ok, _Info} -> base_measurement(Purpose, Inventory, Req, Opts);
                        {error, _} -> observation(Purpose, Inventory, Opts)
                    end
            end;
        {error, Reason} ->
            %% GPU TEE is optional, and some nodes may also lack the
            %% inventory device (or nvidia-smi). Preserve a successful
            %% observation envelope so the measurement remains useful on
            %% non-TEE hosts instead of turning an optional capability into
            %% an inference failure.
            observation(Purpose, unavailable_inventory(Reason), Opts, Reason)
    end.

%% @doc Resolve the inventory through AO-Core device dispatch.
inventory(Root, Opts) ->
    case hb_ao:resolve(
        #{<<"device">> => <<"gpu_inventory@1.0">>},
        #{<<"path">> => <<"report">>, <<"gpu-inventory-root">> => Root},
        Opts
    ) of
        {ok, Response} ->
            {ok, hb_ao:get(<<"body">>, Response, Opts)};
        {error, Reason} -> {error, Reason}
    end.

unavailable_inventory(Reason) ->
    Stable = #{<<"devices">> => [],
        <<"topology">> => #{<<"device-count">> => 0}},
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
        <<"topology">> => #{<<"device-count">> => 0},
        <<"inventory-digest">> => hb_util:encode(
            crypto:hash(sha256, hb_json:encode(Stable))),
        <<"errors">> => [hb_util:bin(Reason)]
    }.

%% @doc Compose through Sam's public measurement protocol without replacing
%% its fixed system/node subject. Fresh evidence binds this inventory and the
%% caller's nonce (the inference request digest) through the backend nonce.
base_measurement(Purpose, Inventory, Req, Opts) ->
    Binding = #{
        <<"request-nonce">> => hb_ao:get(<<"nonce">>, Req,
            hb_util:encode(crypto:strong_rand_bytes(32)), Opts),
        <<"gpu-inventory-digest">> => maps:get(<<"inventory-digest">>, Inventory)
    },
    Nonce = hb_util:encode(crypto:hash(sha256, hb_json:encode(Binding))),
    Path = atom_to_binary(Purpose, utf8),
    case hb_ao:resolve(
        #{<<"device">> => <<"measurement@1.0">>},
        #{<<"path">> => Path, <<"nonce">> => Nonce}, Opts
    ) of
        {ok, Response} ->
            Envelope = case hb_ao:get(<<"type">>, Response, undefined, Opts) of
                <<"lapee-measurement">> -> Response;
                _ -> hb_ao:get(<<"body">>, Response, #{}, Opts)
            end,
            case hb_ao:get(<<"type">>, Envelope, undefined, Opts) of
                <<"lapee-measurement">> ->
                    {ok, #{<<"status">> => 200, <<"body">> =>
                        add_composition_metadata(Envelope, Inventory,
                            Binding, Opts)}};
                _ -> observation(Purpose, Inventory, Opts, Response)
            end;
        {error, Reason} -> observation(Purpose, Inventory, Opts, Reason)
    end.

%% @doc Build a signed observation envelope without claiming host measurement.
observation(Purpose, Inventory, Opts) ->
    observation(Purpose, Inventory, Opts, undefined).

%% @doc Build an observation envelope and preserve an integration failure.
observation(Purpose, Inventory, Opts, Failure) ->
    CpuTee = cpu_tee_observation(),
    GpuTee = gpu_tee_observation(Opts),
    Body0 = #{
        <<"type">> => <<"apus-gpu-system-measurement">>,
        <<"version">> => ?VERSION,
        <<"purpose">> => atom_to_binary(Purpose, utf8),
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"measurement-integration">> => false,
        <<"integration-mode">> => <<"observation-only">>,
        <<"provenance-class">> => <<"host-observed">>,
        <<"cpu-tee">> => CpuTee,
        <<"gpu-tee">> => GpuTee,
        <<"gpu-inventory">> => Inventory,
        <<"gpu-inventory-digest">> =>
            maps:get(<<"inventory-digest">>, Inventory, undefined),
        <<"failure">> => reason_or_undefined(Failure)
    },
    Signed = try hb_message:commit(Body0, Opts)
    catch _:_ -> Body0
    end,
    {ok, #{<<"status">> => 200, <<"body">> => Signed}}.

%% The SNP guest device is the CPU TEE boundary for the H100 workload. This
%% records its availability separately from a verified SNP report, so callers
%% do not confuse a present guest device with a completed report verification.
cpu_tee_observation() ->
    case file:read_file_info("/dev/sev-guest") of
        {ok, #file_info{type = Type}} when Type =:= device; Type =:= regular -> #{
            <<"type">> => <<"amd-sev-snp">>,
            <<"available">> => true,
            <<"verified">> => false,
            <<"device">> => <<"/dev/sev-guest">>,
            <<"report-generated">> => false,
            <<"reason">> => <<"SNP guest device is present; measurement generation did not complete.">>
        };
        _ -> #{
            <<"type">> => <<"amd-sev-snp">>,
            <<"available">> => false,
            <<"verified">> => false,
            <<"reason">> => <<"SNP guest device unavailable">>
        }
    end.

%% Ask the NVIDIA attestation device for a fresh nonce-bound report. The
%% returned claims are kept in the signed measurement envelope.
gpu_tee_observation(Opts) ->
    Nonce = hex_nonce(),
    try hb_ao:resolve(#{<<"device">> => <<"sev_gpu@1.0">>},
        #{<<"path">> => <<"generate">>, <<"nonce">> => Nonce}, Opts) of
        {ok, Raw} ->
            Claims = try hb_json:decode(Raw) catch _:_ -> #{<<"raw">> => Raw} end,
            Claims#{<<"available">> => true, <<"nonce">> => Nonce,
                    <<"device">> => <<"sev_gpu@1.0">>};
        _ -> #{<<"available">> => false, <<"device">> => <<"sev_gpu@1.0">>,
            <<"reason">> => <<"GPU TEE unavailable; host-observed inventory retained">>}
    catch _:_ -> #{<<"available">> => false, <<"device">> => <<"sev_gpu@1.0">>,
        <<"reason">> => <<"GPU TEE unavailable; host-observed inventory retained">>}
    end.

hex_nonce() ->
    list_to_binary(io_lib:format("~64.16.0b", [
        binary:decode_unsigned(crypto:strong_rand_bytes(32))])).

%% @doc Return an observation result after checking its committed body ID.
verify_observation(Envelope, Opts) when is_map(Envelope) ->
    Body = hb_ao:get(<<"body">>, Envelope, Envelope, Opts),
    Expected = hb_ao:get(<<"observation-id">>, Envelope, undefined, Opts),
    Actual = hb_message:id(Body, none, Opts),
    {ok, #{<<"status">> => 200, <<"body">> => #{
        <<"verified">> => Expected =:= undefined orelse Expected =:= Actual,
        <<"provenance-class">> => <<"host-observed">>,
        <<"observation-id">> => Actual
    }}};
verify_observation(_Envelope, _Opts) ->
    {error, #{<<"status">> => 400, <<"body">> => #{
        <<"error">> => <<"invalid-observation">>
    }}}.

%% @doc Retain Sam's envelope and verification checks, alongside the GPU
%% evidence and the nonce binding used by a fresh measurement.
add_composition_metadata(Envelope, Inventory, Binding, Opts) ->
    Verification = case hb_ao:resolve(
        #{<<"device">> => <<"measurement@1.0">>},
        #{<<"path">> => <<"verify">>, <<"envelope">> => Envelope}, Opts
    ) of
        {ok, Result} -> hb_ao:get(<<"body">>, Result, Result, Opts);
        _ -> #{<<"verified">> => false}
    end,
    Evidence = hb_ao:get(<<"evidence">>, Envelope, #{}, Opts),
    Subject = hb_ao:get(<<"body">>, Envelope, #{}, Opts),
    Envelope#{
        <<"cpu-tee">> => #{
            <<"type">> => <<"amd-sev-snp">>,
            <<"available">> => hb_ao:get(<<"type">>, Evidence, undefined, Opts)
                =:= <<"lapee-snp-evidence">>,
            <<"report-generated">> => hb_ao:get(<<"report-raw">>, Evidence,
                undefined, Opts) =/= undefined,
            <<"verified">> => hb_ao:get(<<"verified">>, Verification, false, Opts),
            <<"verification">> => Verification,
            <<"report">> => Evidence
        },
        <<"gpu-tee">> => gpu_tee_observation(Opts),
        <<"apus-gpu-composition">> => #{
            <<"type">> => <<"apus-gpu-system-measurement">>,
            <<"version">> => ?VERSION,
            <<"measurement-integration">> => true,
            <<"integration-mode">> => <<"measurement-nonce">>,
            <<"base-measurement-id">> => hb_message:id(Envelope, signed, Opts),
            <<"gpu-inventory-digest">> => maps:get(<<"inventory-digest">>, Inventory),
            <<"nonce-binding">> => Binding,
            <<"subject-id">> => hb_message:id(Subject, none, Opts),
            <<"provenance-class">> => <<"host-measured-subject">>
        }
    }.

%% @doc Determine whether the existing measurement device is available.
base_measurement_info(Opts) ->
    try hb_ao:resolve(<<"~measurement@1.0/info">>, Opts) of
        {ok, Response} -> {ok, Response};
        {error, Reason} -> {error, Reason}
    catch
        _:_ -> {error, unavailable}
    end.

%% @doc Read a caller-selected mode, defaulting to automatic composition.
requested_mode(Base, Req, Opts) ->
    case first_defined([
        hb_ao:get(<<"measurement-mode">>, Req, undefined, Opts),
        hb_ao:get(<<"measurement-mode">>, Base, undefined, Opts),
        maps:get(<<"measurement-mode">>, Opts, undefined)
    ]) of
        <<"observation-only">> -> 'observation-only';
        <<"hook-body">> -> 'hook-body';
        'observation-only' -> 'observation-only';
        'hook-body' -> 'hook-body';
        _ -> auto
    end.

%% @doc Resolve the same inventory fixture root used by the inventory device.
inventory_root(Base, Req, Opts) ->
    case first_defined([
        hb_ao:get(<<"gpu-inventory-root">>, Req, undefined, Opts),
        hb_ao:get(<<"gpu-inventory-root">>, Base, undefined, Opts),
        maps:get(<<"gpu-inventory-root">>, Opts, undefined)
    ]) of
        undefined -> <<"/sys">>;
        Root when is_binary(Root) -> Root;
        Root when is_list(Root) -> list_to_binary(Root)
    end.

%% @doc Convert an optional failure to a response-safe value.
reason_or_undefined(undefined) -> undefined;
reason_or_undefined(Reason) when is_map(Reason) -> hb_json:encode(hb_private:reset(Reason));
reason_or_undefined(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

%% @doc Return the first non-undefined value.
first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value.

-ifdef(TEST).

mode_defaults_to_auto_test() ->
    ?assertEqual(auto, requested_mode(#{}, #{}, #{})).

mode_can_be_forced_test() ->
    ?assertEqual('observation-only',
        requested_mode(#{}, #{<<"measurement-mode">> => <<"observation-only">>}, #{})).

unavailable_inventory_stays_observable_test() ->
    Inventory = unavailable_inventory(<<"gpu_inventory@1.0 unavailable">>),
    ?assertEqual(false, maps:get(<<"supported">>, Inventory)),
    ?assertEqual([], maps:get(<<"devices">>, Inventory)),
    ?assert(is_binary(maps:get(<<"inventory-digest">>, Inventory))).

-endif.
