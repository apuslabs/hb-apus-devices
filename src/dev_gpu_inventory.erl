%%% @doc Host-observed GPU and PCIe inventory for Device Forge nodes.
%%%
%%% The device reports read-only host facts. It does not make an attestation
%%% claim and it keeps volatile runtime values out of the static digest.
-module(dev_gpu_inventory).
-implements(<<"gpu_inventory@1.0">>).
-export([info/1, report/3, digest/3, snapshot/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).

%% @doc Return the public device description.
info(_Opts) ->
    #{
        exports => [<<"report">>, <<"digest">>, <<"snapshot">>],
        description => <<"Host-observed GPU and PCIe inventory">>,
        version => ?VERSION
    }.

%% @doc Return stable GPU and PCIe facts with a canonical inventory digest.
report(Base, Req, Opts) ->
    Root = inventory_root(Base, Req, Opts),
    Report = collect_report(Root, Opts),
    {ok, #{<<"status">> => 200, <<"body">> => Report}}.

%% @doc Return the stable digest and the inventory it commits to.
digest(Base, Req, Opts) ->
    {ok, #{<<"body">> := Report}} = report(Base, Req, Opts),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"type">> => <<"apus-gpu-inventory-digest">>,
            <<"version">> => ?VERSION,
            <<"inventory-digest">> => maps:get(<<"inventory-digest">>, Report),
            <<"provenance-class">> => <<"host-observed">>
        }
    }}.

%% @doc Return volatile runtime facts as a lower-trust observation.
snapshot(Base, Req, Opts) ->
    Root = inventory_root(Base, Req, Opts),
    {Rows, Sources, Errors} = nvidia_snapshot(Root),
    {ok, #{<<"status">> => 200, <<"body">> => #{
        <<"type">> => <<"apus-gpu-runtime-snapshot">>,
        <<"version">> => ?VERSION,
        <<"collected-at-unix">> => erlang:system_time(second),
        <<"provenance">> => #{
            <<"class">> => <<"runtime-observed">>,
            <<"sources">> => Sources
        },
        <<"supported">> => Rows =/= [],
        <<"devices">> => Rows,
        <<"errors">> => Errors
    }}}.

%% @doc Collect static facts from sysfs and optional nvidia-smi output.
collect_report(Root, _Opts) ->
    {SysfsRows, SysfsSources, SysfsErrors} = sysfs_inventory(Root),
    {NvidiaRows, NvidiaSources, NvidiaErrors} = nvidia_inventory(Root),
    Rows = merge_rows(SysfsRows, NvidiaRows),
    StableRows = [stable_row(Row) || Row <- lists:sort(fun row_less/2, Rows)],
    Digest = digest_for(#{
        <<"devices">> => StableRows,
        <<"topology">> => topology(StableRows)
    }),
    #{
        <<"type">> => <<"apus-gpu-inventory">>,
        <<"version">> => ?VERSION,
        <<"collected-at-unix">> => erlang:system_time(second),
        <<"provenance">> => #{
            <<"class">> => <<"host-observed">>,
            <<"sources">> => lists:usort(SysfsSources ++ NvidiaSources)
        },
        <<"supported">> => StableRows =/= [],
        <<"devices">> => StableRows,
        <<"topology">> => topology(StableRows),
        <<"inventory-digest">> => Digest,
        <<"errors">> => SysfsErrors ++ NvidiaErrors
    }.

%% @doc Resolve an optional fixture root without making it part of the report.
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

%% @doc Read PCI display and accelerator devices from sysfs.
sysfs_inventory(Root) ->
    PciDir = filename:join(binary_to_list(Root), "bus/pci/devices"),
    case file:list_dir(PciDir) of
        {ok, Names} ->
            {Rows, Errors} = lists:foldl(
                fun(Name, {Acc, ErrAcc}) ->
                    case sysfs_row(PciDir, Name, Root) of
                        {ok, Row} -> {[Row | Acc], ErrAcc};
                        skip -> {Acc, ErrAcc};
                        {error, Error} -> {Acc, [Error | ErrAcc]}
                    end
                end,
                {[], []},
                lists:sort(Names)
            ),
            {lists:reverse(Rows), [<<"sysfs">>], lists:reverse(Errors)};
        {error, enoent} -> {[], [], []};
        {error, Reason} -> {[], [], [error_text(<<"sysfs">>, Reason)]}
    end.

%% @doc Build a GPU row when the PCI class identifies a display/accelerator.
sysfs_row(PciDir, Bdf, Root) ->
    Dir = filename:join(PciDir, Bdf),
    case read_text(filename:join(Dir, "class")) of
        {ok, Class} ->
            case is_gpu_class(Class) of
                false -> skip;
                true ->
                    Driver = driver_name(filename:join(Dir, "driver")),
                    {ok, #{
                <<"pci-bdf">> => list_to_binary(Bdf),
                <<"class">> => Class,
                <<"vendor-id">> => read_optional(Dir, "vendor"),
                <<"device-id">> => read_optional(Dir, "device"),
                <<"subsystem-vendor-id">> =>
                    read_optional(Dir, "subsystem_vendor"),
                <<"subsystem-device-id">> =>
                    read_optional(Dir, "subsystem_device"),
                <<"revision">> => read_optional(Dir, "revision"),
                <<"driver">> => Driver,
                <<"driver-version">> => driver_version(Root, Driver),
                <<"iommu-group">> => iommu_group(filename:join(Dir, "iommu_group")),
                <<"pcie-link">> => #{
                    <<"speed">> => read_optional(Dir, "current_link_speed"),
                    <<"width">> => read_optional(Dir, "current_link_width")
                },
                <<"drm-card">> => drm_card(Root, Bdf)
                    }}
            end;
        {error, enoent} -> skip;
        {error, Reason} -> {error, error_text(list_to_binary(Bdf), Reason)}
    end.

%% @doc Add NVIDIA-specific identity and capacity fields when nvidia-smi exists.
nvidia_inventory(Root) ->
    case nvidia_query([
        "index", "name", "pci.bus_id", "driver_version", "uuid",
        "memory.total", "compute_cap", "vbios_version",
        "pcie.link.gen.current", "pcie.link.width.current", "power.limit",
        "persistence_mode", "ecc.mode.current", "mig.mode.current"
    ]) of
        {ok, Rows} ->
            {[
                nvidia_row(Row, Root) || Row <- Rows
            ], [<<"nvidia-smi">>], []};
        {error, not_found} -> {[], [], []};
        {error, Reason} -> {[], [<<"nvidia-smi">>], [error_text(<<"nvidia-smi">>, Reason)]}
    end.

%% @doc Read the NVIDIA runtime query used by the snapshot endpoint.
nvidia_snapshot(_Root) ->
    case nvidia_query([
        "index", "name", "pci.bus_id", "temperature.gpu", "power.draw",
        "power.limit", "utilization.gpu", "utilization.memory", "memory.used",
        "memory.total", "clocks.current.graphics", "clocks.current.sm",
        "clocks.current.memory", "pstate", "fan.speed"
    ]) of
        {ok, Rows} ->
            {[nvidia_runtime_row(Row) || Row <- Rows], [<<"nvidia-smi">>], []};
        {error, not_found} -> {[], [], []};
        {error, Reason} -> {[], [<<"nvidia-smi">>], [error_text(<<"nvidia-smi">>, Reason)]}
    end.

%% @doc Execute a fixed nvidia-smi query without accepting shell input.
nvidia_query(Fields) ->
    case os:find_executable("nvidia-smi") of
        false -> {error, not_found};
        Executable ->
            Query = string:join(Fields, ","),
            Command = Executable ++ " --query-gpu=" ++ Query ++
                " --format=csv,noheader,nounits",
            case os:cmd(Command) of
                Output when is_list(Output) -> parse_csv_rows(Output, length(Fields));
                _ -> {error, command_failed}
            end
    end.

%% @doc Convert one nvidia-smi row into stable inventory fields.
nvidia_row(Row, _Root) ->
    #{
        <<"pci-bdf">> => csv_value(Row, 3),
        <<"vendor-id">> => <<"0x10de">>,
        <<"name">> => csv_value(Row, 2),
        <<"driver-version">> => csv_value(Row, 4),
        <<"gpu-uuid">> => csv_value(Row, 5),
        <<"vram-bytes">> => mib_to_bytes(csv_value(Row, 6)),
        <<"compute-capability">> => csv_value(Row, 7),
        <<"vbios-version">> => csv_value(Row, 8),
        <<"pcie-link-gen">> => csv_value(Row, 9),
        <<"pcie-link-width">> => csv_value(Row, 10),
        <<"power-limit-watts">> => number_or_text(csv_value(Row, 11)),
        <<"persistence-mode">> => csv_value(Row, 12),
        <<"ecc-mode">> => csv_value(Row, 13),
        <<"mig-mode">> => csv_value(Row, 14),
        <<"source">> => <<"nvidia-smi">>
    }.

%% @doc Convert one nvidia-smi runtime row into volatile fields.
nvidia_runtime_row(Row) ->
    #{
        <<"pci-bdf">> => csv_value(Row, 3),
        <<"name">> => csv_value(Row, 2),
        <<"temperature-c">> => number_or_text(csv_value(Row, 4)),
        <<"power-watts">> => number_or_text(csv_value(Row, 5)),
        <<"power-limit-watts">> => number_or_text(csv_value(Row, 6)),
        <<"utilization-gpu-percent">> => number_or_text(csv_value(Row, 7)),
        <<"utilization-memory-percent">> => number_or_text(csv_value(Row, 8)),
        <<"memory-used-mib">> => number_or_text(csv_value(Row, 9)),
        <<"memory-total-mib">> => number_or_text(csv_value(Row, 10)),
        <<"graphics-clock-mhz">> => number_or_text(csv_value(Row, 11)),
        <<"sm-clock-mhz">> => number_or_text(csv_value(Row, 12)),
        <<"memory-clock-mhz">> => number_or_text(csv_value(Row, 13)),
        <<"pstate">> => csv_value(Row, 14),
        <<"fan-speed-percent">> => number_or_text(csv_value(Row, 15))
    }.

%% @doc Parse comma-separated output while preserving empty fields.
parse_csv_rows(Output, Width) ->
    Lines = [string:trim(Line) || Line <- string:split(Output, "\n", all),
        string:trim(Line) =/= ""],
    Rows = [
        [string:trim(Field) || Field <- string:split(Line, ",", all)]
        || Line <- Lines
    ],
    case lists:all(fun(Row) -> length(Row) =:= Width end, Rows) of
        true -> {ok, Rows};
        false -> {error, malformed_output}
    end.

%% @doc Merge sysfs and NVIDIA rows by PCI BDF, preserving provenance fields.
merge_rows(SysfsRows, NvidiaRows) ->
    lists:foldl(
        fun(Nvidia, Acc) ->
            Bdf = maps:get(<<"pci-bdf">>, Nvidia, <<>>),
            case lists:keytake(Bdf, 1, [{maps:get(<<"pci-bdf">>, R, <<>>), R} || R <- Acc]) of
                {value, {Bdf, Existing}, Rest} ->
                    [maps:merge(Existing, Nvidia) | [R || {_K, R} <- Rest]];
                false -> [Nvidia | Acc]
            end
        end,
        SysfsRows,
        NvidiaRows
    ).

%% @doc Keep fields that describe identity, driver, topology, and linkage.
stable_row(Row) ->
    maps:without([
        <<"source">>, <<"temperature-c">>, <<"power-watts">>,
        <<"utilization-gpu-percent">>, <<"utilization-memory-percent">>,
        <<"memory-used-mib">>
    ], Row).

%% @doc Return a deterministic topology summary.
topology(Rows) ->
    #{
        <<"device-count">> => length(Rows),
        <<"pci-bdfs">> => lists:sort([
            maps:get(<<"pci-bdf">>, Row, <<>>) || Row <- Rows
        ]),
        <<"iommu-groups">> => lists:sort(lists:usort([
            Group || Row <- Rows,
                Group <- [maps:get(<<"iommu-group">>, Row, undefined)],
                Group =/= undefined
        ]))
    }.

%% @doc Hash a canonical JSON representation of stable inventory data.
digest_for(Value) ->
    hb_util:encode(crypto:hash(sha256, hb_json:encode(Value))).

%% @doc Determine whether a PCI class is a display or accelerator class.
is_gpu_class(<<"0x", A, B, _/binary>>) ->
    lists:member({A, B}, [{$0, $3}, {$1, $2}]);
is_gpu_class(_) -> false.

%% @doc Read a trimmed text file.
read_text(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, list_to_binary(string:trim(binary_to_list(Bin)))};
        Error -> Error
    end.

%% @doc Return a file value or an explicit unavailable marker.
read_optional(Dir, Name) ->
    case read_text(filename:join(Dir, Name)) of
        {ok, Value} -> Value;
        _ -> undefined
    end.

%% @doc Extract the final component of a driver symlink.
driver_name(Path) ->
    case file:read_link(Path) of
        {ok, Link} -> list_to_binary(filename:basename(Link));
        _ -> undefined
    end.

%% @doc Read a module version from the selected sysfs root.
driver_version(_Root, undefined) -> undefined;
driver_version(Root, Driver) ->
    read_optional(filename:join(binary_to_list(Root), "module/" ++
        binary_to_list(Driver)), "version").

%% @doc Extract the IOMMU group number from its symlink target.
iommu_group(Path) ->
    case file:read_link(Path) of
        {ok, Link} -> list_to_binary(filename:basename(Link));
        _ -> undefined
    end.

%% @doc Find the DRM card associated with a PCI BDF.
drm_card(Root, Bdf) ->
    Dir = filename:join(binary_to_list(Root), "class/drm"),
    case file:list_dir(Dir) of
        {ok, Names} ->
            case lists:dropwhile(
                fun(Name) ->
                    not drm_matches(filename:join(Dir, Name), Bdf)
                end,
                Names
            ) of
                [Name | _] -> list_to_binary(Name);
                [] -> undefined
            end;
        _ -> undefined
    end.

%% @doc Check whether a DRM device symlink ends in the selected BDF.
drm_matches(Path, Bdf) ->
    case file:read_link(filename:join(Path, "device")) of
        {ok, Link} -> filename:basename(Link) =:= Bdf;
        _ -> false
    end.

%% @doc Convert a CSV field to an integer when it is numeric.
number_or_text(undefined) -> undefined;
number_or_text(<<>>) -> undefined;
number_or_text(Value) ->
    try list_to_integer(binary_to_list(Value))
    catch _:_ -> Value
    end.

%% @doc Convert an NVIDIA memory value in MiB to bytes.
mib_to_bytes(Value) ->
    case number_or_text(Value) of
        undefined -> undefined;
        Number when is_integer(Number) -> Number * 1024 * 1024;
        Other -> Other
    end.

%% @doc Read a positional CSV field.
csv_value(Row, Index) ->
    case lists:nth(Index, Row) of
        "" -> undefined;
        Value when is_list(Value) -> list_to_binary(Value);
        Value -> Value
    end.

%% @doc Compare rows by BDF for deterministic output.
row_less(A, B) ->
    maps:get(<<"pci-bdf">>, A, <<>>) =< maps:get(<<"pci-bdf">>, B, <<>>).

%% @doc Return the first non-undefined value.
first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value.

%% @doc Render an unavailable source error without exposing host internals.
error_text(Source, Reason) ->
    <<Source/binary, <<": unavailable (">>/binary,
        (hb_util:bin(Reason))/binary, <<")">>/binary>>.

-ifdef(TEST).

digest_is_stable_test() ->
    ValueA = #{<<"devices">> => [#{<<"pci-bdf">> => <<"0000:01:00.0">>}],
        <<"topology">> => #{<<"device-count">> => 1}},
    ?assertEqual(digest_for(ValueA), digest_for(ValueA)).

volatile_fields_are_excluded_test() ->
    Stable = #{<<"pci-bdf">> => <<"0000:01:00.0">>},
    ?assertEqual(stable_row(Stable#{<<"temperature-c">> => 70}),
        stable_row(Stable#{<<"temperature-c">> => 80})).

csv_parser_test() ->
    ?assertEqual({ok, [["0", "RTX", "0000:01:00.0"]]},
        parse_csv_rows("0, RTX, 0000:01:00.0\n", 3)).

-endif.
