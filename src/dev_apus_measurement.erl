%%% @doc External composition adapter for GPU-aware system measurement.
%%%
%%% When the host exposes `measurement@1.0`, this device supplies a hook body
%%% containing the GPU inventory and preserves the base measurement envelope.
%%% On stock HyperBEAM it returns an explicitly lower-trust observation.
-module(dev_apus_measurement).
-implements(<<"apus_measurement@1.0">>).
-export([info/1, boot/3, fresh/3, verify/3, snapshot/3]).
-include_lib("hb/include/hb.hrl").
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
                'hook-body' -> hook_measurement(Purpose, Inventory, Opts);
                auto ->
                    case base_measurement_info(Opts) of
                        {ok, _Info} -> hook_measurement(Purpose, Inventory, Opts);
                        {error, _} -> observation(Purpose, Inventory, Opts)
                    end
            end;
        {error, Reason} ->
            {error, #{
                <<"status">> => 503,
                <<"body">> => #{
                    <<"error">> => <<"gpu-inventory-unavailable">>,
                    <<"reason">> => hb_util:bin(Reason)
                }
            }}
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

%% @doc Call the existing measurement device using its public hook-body path.
hook_measurement(Purpose, Inventory, Opts) ->
    HookBody = #{
        <<"type">> => <<"apus-gpu-measurement-hook">>,
        <<"version">> => ?VERSION,
        <<"gpu-inventory">> => Inventory,
        <<"gpu-inventory-digest">> =>
            maps:get(<<"inventory-digest">>, Inventory, undefined)
    },
    Path = case Purpose of boot -> <<"boot">>; fresh -> <<"fresh">> end,
    case hb_ao:resolve(
        #{
            <<"device">> => <<"measurement@1.0">>,
            <<"measurement-body-source">> => <<"hook-body">>
        },
        #{<<"path">> => Path, <<"body">> => HookBody},
        Opts
    ) of
        {ok, Response} ->
            BaseBody = hb_ao:get(<<"body">>, Response, Opts),
            {ok, #{
                <<"status">> => hb_ao:get(<<"status">>, Response, 200, Opts),
                <<"body">> => add_composition_metadata(
                    BaseBody, Inventory, true, Opts)
            }};
        {error, Reason} ->
            observation(Purpose, Inventory, Opts, Reason)
    end.

%% @doc Build a signed observation envelope without claiming host measurement.
observation(Purpose, Inventory, Opts) ->
    observation(Purpose, Inventory, Opts, undefined).

%% @doc Build an observation envelope and preserve an integration failure.
observation(Purpose, Inventory, Opts, Failure) ->
    Body0 = #{
        <<"type">> => <<"apus-gpu-system-measurement">>,
        <<"version">> => ?VERSION,
        <<"purpose">> => atom_to_binary(Purpose, utf8),
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"measurement-integration">> => false,
        <<"integration-mode">> => <<"observation-only">>,
        <<"provenance-class">> => <<"host-observed">>,
        <<"gpu-inventory">> => Inventory,
        <<"gpu-inventory-digest">> =>
            maps:get(<<"inventory-digest">>, Inventory, undefined),
        <<"failure">> => reason_or_undefined(Failure)
    },
    Signed = try hb_message:commit(Body0, Opts)
    catch _:_ -> Body0
    end,
    {ok, #{<<"status">> => 200, <<"body">> => Signed}}.

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

%% @doc Add metadata without rewriting the base measurement evidence.
add_composition_metadata(BaseBody, Inventory, Integrated, Opts) ->
    BaseMap = case is_map(BaseBody) of true -> BaseBody; false -> #{} end,
    SubjectID = hb_message:id(BaseMap, none, Opts),
    BaseMap#{
        <<"apus-gpu-composition">> => #{
            <<"type">> => <<"apus-gpu-system-measurement">>,
            <<"version">> => ?VERSION,
            <<"measurement-integration">> => Integrated,
            <<"integration-mode">> => <<"hook-body">>,
            <<"base-measurement-id">> => hb_message:id(BaseMap, signed, Opts),
            <<"gpu-inventory-digest">> =>
                maps:get(<<"inventory-digest">>, Inventory, undefined),
            <<"subject-id">> => SubjectID,
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
reason_or_undefined(Reason) -> hb_util:bin(Reason).

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

-endif.
