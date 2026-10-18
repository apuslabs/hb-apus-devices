%%% @doc Host-observed GPU and PCIe inventory.
%%%
%%% `gpu_inventory@1.0' reads PCI display controllers and 3D/processing
%%% accelerators from the node's sysfs tree, enriches NVIDIA GPUs with a
%%% predefined `nvidia-smi' query, and commits the stable facts to a canonical
%%% digest. It makes no attestation claim: every value is what the host
%%% reports. The sysfs root and the `nvidia-smi' executable are node options;
%%% a request cannot select either. Collections are shared on the node: an
%%% inventory report is reused for a short, configurable time, and requests
%%% that arrive while a collection runs wait for its result instead of
%%% starting another `nvidia-smi' run.
-module(dev_gpu_inventory).
-implements(<<"gpu_inventory@1.0">>).
-specification("docs/spec/gpu_inventory.md").
-export([info/1, report/3, digest/3, snapshot/3]).
-include_lib("hb/include/hb.hrl").

-define(VERSION, <<"1.0">>).
-define(DEFAULT_ROOT, <<"/sys">>).
-define(DEFAULT_NVIDIA_SMI, <<"nvidia-smi">>).
-define(DEFAULT_NVIDIA_SMI_TIMEOUT_MS, 10000).
%% How long a collected inventory report is reused, in milliseconds.
-define(DEFAULT_CACHE_MS, 5000).
%% How long an unused coordinator waits for its start signal.
-define(COORDINATOR_START_MS, 5000).
%% Upper bound on the bytes read from one `nvidia-smi' run.
-define(MAX_NVIDIA_SMI_OUTPUT, 1048576).

%% `nvidia-smi --query-gpu' fields for the stable inventory, in CSV order.
-define(INVENTORY_FIELDS, [
    "index", "name", "pci.bus_id", "driver_version", "uuid",
    "memory.total", "compute_cap", "vbios_version",
    "pcie.link.gen.current", "pcie.link.width.current", "power.limit",
    "persistence_mode", "ecc.mode.current", "mig.mode.current"
]).

%% `nvidia-smi --query-gpu' fields for the runtime snapshot, in CSV order.
-define(RUNTIME_FIELDS, [
    "index", "name", "pci.bus_id", "temperature.gpu", "power.draw",
    "power.limit", "utilization.gpu", "utilization.memory", "memory.used",
    "memory.total", "clocks.current.graphics", "clocks.current.sm",
    "clocks.current.memory", "pstate", "fan.speed"
]).

%% Fields that never enter a stable inventory row.
-define(VOLATILE_FIELDS, [
    <<"source">>, <<"temperature-c">>, <<"power-watts">>,
    <<"utilization-gpu-percent">>, <<"utilization-memory-percent">>,
    <<"memory-used-mib">>
]).

%% @doc Return the keys this device resolves.
-spec info(map()) -> #{ exports := [binary()] }.
info(_Opts) ->
    #{ exports => [<<"report">>, <<"digest">>, <<"snapshot">>] }.

%% @doc Return the stable GPU inventory and its digest.
-spec report(#{ _ => _ }, #{ _ => _ }, map()) -> {ok, map()}.
report(_Base, _Req, Opts) ->
    {ok, inventory_report(Opts)}.

%% @doc Return the inventory digest without the inventory itself.
-spec digest(#{ _ => _ }, #{ _ => _ }, map()) -> {ok, map()}.
digest(_Base, _Req, Opts) ->
    Report = inventory_report(Opts),
    {ok, #{
        <<"type">> => <<"apus-gpu-inventory-digest">>,
        <<"version">> => ?VERSION,
        <<"inventory-digest">> => maps:get(<<"inventory-digest">>, Report),
        <<"provenance-class">> => <<"host-observed">>
    }}.

%% @doc Return volatile runtime facts from `nvidia-smi'. They are not part of
%% any digest.
-spec snapshot(#{ _ => _ }, #{ _ => _ }, map()) -> {ok, map()}.
snapshot(_Base, _Req, Opts) ->
    {ok, shared(snapshot, 0, fun() -> collect_snapshot(Opts) end, Opts)}.

%% @doc Read the runtime fields from `nvidia-smi'.
collect_snapshot(Opts) ->
    {Rows, Sources, Errors} =
        case nvidia_query(?RUNTIME_FIELDS, Opts) of
            {ok, CSV} ->
                {[compact(nvidia_runtime_row(Row)) || Row <- CSV], [<<"nvidia-smi">>], []};
            {error, not_found} ->
                {[], [], []};
            {error, Reason} ->
                {[], [<<"nvidia-smi">>], [error_text(<<"nvidia-smi">>, Reason)]}
        end,
    #{
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
    }.

%%% ------------------------------------------------------------------
%%% Inventory
%%% ------------------------------------------------------------------

%% @doc The inventory report: a report collected within the last
%% `gpu-inventory-cache-ms' milliseconds, or a new collection.
inventory_report(Opts) ->
    shared(report, cache_ms(Opts), fun() -> collect_report(Opts) end, Opts).

%% @doc Collect sysfs and `nvidia-smi' facts into the inventory report.
collect_report(Opts) ->
    Root = inventory_root(Opts),
    {SysfsRows, SysfsSources, SysfsErrors} = sysfs_inventory(Root),
    {NvidiaRows, NvidiaSources, NvidiaErrors} = nvidia_inventory(Opts),
    Rows = merge_rows(SysfsRows, NvidiaRows),
    StableRows = [stable_row(Row) || Row <- lists:sort(fun row_less/2, Rows)],
    Topology = topology(StableRows),
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
        <<"topology">> => Topology,
        <<"inventory-digest">> => digest_for(StableRows, Topology),
        <<"errors">> => SysfsErrors ++ NvidiaErrors
    }.

%% @doc The sysfs root from the `gpu-inventory-root' node option.
inventory_root(Opts) ->
    case hb_opts:get(<<"gpu-inventory-root">>, ?DEFAULT_ROOT, Opts) of
        Root when is_binary(Root) -> Root;
        Root when is_list(Root) -> unicode:characters_to_binary(Root);
        _ -> ?DEFAULT_ROOT
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

%% @doc Build a row for a PCI function whose class is a display controller
%% (`0x03') or a processing accelerator (`0x12').
sysfs_row(PciDir, Bdf, Root) ->
    Dir = filename:join(PciDir, Bdf),
    case read_text(filename:join(Dir, "class")) of
        {ok, Class} ->
            case is_gpu_class(Class) of
                false -> skip;
                true ->
                    Driver = link_name(filename:join(Dir, "driver")),
                    {ok, #{
                        <<"pci-bdf">> => list_to_binary(Bdf),
                        <<"class">> => Class,
                        <<"vendor-id">> => read_optional(Dir, "vendor"),
                        <<"device-id">> => read_optional(Dir, "device"),
                        <<"subsystem-vendor-id">> => read_optional(Dir, "subsystem_vendor"),
                        <<"subsystem-device-id">> => read_optional(Dir, "subsystem_device"),
                        <<"revision">> => read_optional(Dir, "revision"),
                        <<"driver">> => Driver,
                        <<"driver-version">> => driver_version(Root, Driver),
                        <<"iommu-group">> => link_name(filename:join(Dir, "iommu_group")),
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

%% @doc NVIDIA identity and capacity fields from `nvidia-smi', when present.
nvidia_inventory(Opts) ->
    case nvidia_query(?INVENTORY_FIELDS, Opts) of
        {ok, CSV} -> {[nvidia_row(Row) || Row <- CSV], [<<"nvidia-smi">>], []};
        {error, not_found} -> {[], [], []};
        {error, Reason} -> {[], [<<"nvidia-smi">>], [error_text(<<"nvidia-smi">>, Reason)]}
    end.

%% @doc Convert one `nvidia-smi' inventory row into stable fields.
nvidia_row(Row) ->
    #{
        <<"pci-bdf">> => normalize_bdf(csv_value(Row, 3)),
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

%% @doc Convert one `nvidia-smi' runtime row into volatile fields.
nvidia_runtime_row(Row) ->
    #{
        <<"pci-bdf">> => normalize_bdf(csv_value(Row, 3)),
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

%% @doc `nvidia-smi' prints PCI addresses with an 8-digit domain in upper
%% case (`00000000:3B:00.0'); sysfs uses at least four lower-case domain
%% digits (`0000:3b:00.0'). Rows are keyed by the sysfs form.
normalize_bdf(undefined) ->
    undefined;
normalize_bdf(Bdf) ->
    Lower = hb_util:to_lower(Bdf),
    case binary:split(Lower, <<":">>) of
        [Domain, Rest] when byte_size(Domain) > 4 ->
            <<(trim_domain(Domain))/binary, ":", Rest/binary>>;
        _ ->
            Lower
    end.

trim_domain(<<"0", Rest/binary>>) when byte_size(Rest) >= 4 -> trim_domain(Rest);
trim_domain(Domain) -> Domain.

%% @doc Merge `nvidia-smi' rows into sysfs rows with the same PCI address;
%% `nvidia-smi' values take precedence for shared fields.
merge_rows(SysfsRows, NvidiaRows) ->
    lists:foldl(
        fun(Nvidia, Acc) ->
            Bdf = maps:get(<<"pci-bdf">>, Nvidia, undefined),
            case lists:partition(
                fun(Row) -> maps:get(<<"pci-bdf">>, Row, undefined) =:= Bdf end,
                Acc
            ) of
                {[Existing | _], Rest} when Bdf =/= undefined ->
                    [maps:merge(Existing, Nvidia) | Rest];
                _ ->
                    [Nvidia | Acc]
            end
        end,
        SysfsRows,
        NvidiaRows
    ).

%% @doc Keep the fields that describe identity, driver, topology and links.
stable_row(Row) ->
    compact(maps:without(?VOLATILE_FIELDS, Row)).

%% @doc Drop unknown values, so that a row holds exactly the facts the host
%% reported and the digest can be recomputed from the reported rows.
compact(Row) ->
    maps:filtermap(
        fun
            (_Key, undefined) -> false;
            (_Key, Map) when is_map(Map) ->
                case compact(Map) of
                    Empty when map_size(Empty) =:= 0 -> false;
                    Compacted -> {true, Compacted}
                end;
            (_Key, _Value) -> true
        end,
        Row
    ).

%% @doc A deterministic topology summary.
topology(Rows) ->
    #{
        <<"device-count">> => length(Rows),
        <<"pci-bdfs">> => lists:sort([maps:get(<<"pci-bdf">>, Row, <<>>) || Row <- Rows]),
        <<"iommu-groups">> => lists:usort([
            Group
        ||
            Row <- Rows,
            Group <- [maps:get(<<"iommu-group">>, Row, undefined)],
            Group =/= undefined
        ])
    }.

%% @doc base64url (unpadded) SHA-256 of the compact JSON encoding of the
%% stable rows and topology.
digest_for(Rows, Topology) ->
    Canonical = hb_json:encode(#{ <<"devices">> => Rows, <<"topology">> => Topology }),
    hb_util:encode(crypto:hash(sha256, Canonical)).

%% @doc PCI base class `0x03' (display) or `0x12' (processing accelerator).
is_gpu_class(<<"0x", A, B, _/binary>>) ->
    lists:member({A, B}, [{$0, $3}, {$1, $2}]);
is_gpu_class(_) ->
    false.

%%% ------------------------------------------------------------------
%%% nvidia-smi
%%% ------------------------------------------------------------------

%% @doc Run a predefined `nvidia-smi --query-gpu' query and parse its CSV output.
nvidia_query(Fields, Opts) ->
    maybe
        {ok, Path} ?= nvidia_smi(Opts),
        Args = [
            "--query-gpu=" ++ string:join(Fields, ","),
            "--format=csv,noheader,nounits"
        ],
        {ok, 0, Output} ?= run(Path, Args, timeout(Opts)),
        parse_csv_rows(binary_to_list(Output), length(Fields))
    else
        {ok, Status, _} when is_integer(Status) -> {error, {exit_status, Status}};
        {error, _} = Error -> Error
    end.

%% @doc The `nvidia-smi' executable. An absolute path is used as configured;
%% a bare name is looked up in the node's `PATH'. A missing executable
%% means the host has no NVIDIA tooling, which is not an error.
nvidia_smi(Opts) ->
    Configured = nvidia_smi_option(Opts),
    case filename:pathtype(Configured) of
        absolute ->
            case filelib:is_regular(Configured) of
                true -> {ok, Configured};
                false -> {error, not_found}
            end;
        _ ->
            case lists:member($/, Configured) of
                true -> {error, not_found};
                false ->
                    case os:find_executable(Configured) of
                        false -> {error, not_found};
                        Path -> {ok, Path}
                    end
            end
    end.

%% @doc The configured `nvidia-smi' path or name, as a string.
nvidia_smi_option(Opts) ->
    case hb_opts:get(<<"gpu-inventory-nvidia-smi-path">>, ?DEFAULT_NVIDIA_SMI, Opts) of
        Value when is_binary(Value); is_list(Value) -> hb_util:list(Value);
        _ -> hb_util:list(?DEFAULT_NVIDIA_SMI)
    end.

%% @doc The limit, in milliseconds, for one `nvidia-smi' run.
timeout(Opts) ->
    integer_option(<<"gpu-inventory-nvidia-smi-timeout">>,
        ?DEFAULT_NVIDIA_SMI_TIMEOUT_MS, 1, Opts).

%% @doc How long, in milliseconds, a collected inventory report is reused.
cache_ms(Opts) ->
    integer_option(<<"gpu-inventory-cache-ms">>, ?DEFAULT_CACHE_MS, 0, Opts).

%% @doc An integer node option of at least `Min', given as an integer or a
%% decimal string; other values select `Default'.
integer_option(Key, Default, Min, Opts) ->
    case hb_opts:get(Key, Default, Opts) of
        Value when is_integer(Value), Value >= Min -> Value;
        Bin when is_binary(Bin) ->
            try binary_to_integer(Bin) of
                Value when Value >= Min -> Value;
                _ -> Default
            catch _:_ -> Default
            end;
        _ -> Default
    end.

%% @doc Run an executable without a shell and collect its standard output
%% for at most `Timeout' milliseconds. On timeout the device closes the port,
%% which closes the process's standard input and output; the process itself
%% ends when it next writes output or exits on its own.
run(Path, Args, Timeout) ->
    PortOpts = [{args, Args}, binary, exit_status, use_stdio, hide],
    try open_port({spawn_executable, Path}, PortOpts) of
        Port ->
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            collect_output(Port, Deadline, [], 0)
    catch
        error:Reason -> {error, {spawn_failed, Reason}}
    end.

collect_output(Port, Deadline, Acc, Size) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} when Size + byte_size(Data) =< ?MAX_NVIDIA_SMI_OUTPUT ->
            collect_output(Port, Deadline, [Data | Acc], Size + byte_size(Data));
        {Port, {data, _}} ->
            close_port(Port),
            {error, output_too_large};
        {Port, {exit_status, Status}} ->
            flush_port(Port),
            {ok, Status, iolist_to_binary(lists:reverse(Acc))}
    after Remaining ->
        close_port(Port),
        {error, timeout}
    end.

close_port(Port) ->
    catch port_close(Port),
    flush_port(Port).

flush_port(Port) ->
    receive
        {Port, _} -> flush_port(Port);
        {'EXIT', Port, _} -> flush_port(Port)
    after 0 -> ok
    end.

%% @doc Parse comma-separated rows, keeping empty fields. Every row must have
%% exactly `Width' fields.
parse_csv_rows(Output, Width) ->
    Lines = [
        string:trim(Line)
    ||
        Line <- string:split(Output, "\n", all),
        string:trim(Line) =/= ""
    ],
    Rows = [[string:trim(Field) || Field <- string:split(Line, ",", all)] || Line <- Lines],
    case lists:all(fun(Row) -> length(Row) =:= Width end, Rows) of
        true -> {ok, Rows};
        false -> {error, malformed_output}
    end.

%%% ------------------------------------------------------------------
%%% Shared collection
%%% ------------------------------------------------------------------

%% @doc The result of `Collect', shared between requests of the same kind
%% and configuration. A finished result younger than `MaxAge' milliseconds
%% is returned as it is; a request that arrives while a collection runs
%% receives that collection's result; otherwise a new collection starts.
%% A coordinator process, started on first use and registered under this
%% module's name, tracks the collections, and each collection runs in a
%% process of its own. When the coordinator or a collection is unavailable,
%% the request collects for itself.
shared(Kind, MaxAge, Collect, Opts) ->
    Key = {Kind, inventory_root(Opts), nvidia_smi_option(Opts), timeout(Opts)},
    case coordinator() of
        {ok, Coordinator} ->
            Monitor = erlang:monitor(process, Coordinator),
            Coordinator ! {collect, self(), Monitor, Key, MaxAge, Collect},
            receive
                {Monitor, {ok, Result}} ->
                    erlang:demonitor(Monitor, [flush]),
                    Result;
                {Monitor, failed} ->
                    erlang:demonitor(Monitor, [flush]),
                    Collect();
                {'DOWN', Monitor, process, Coordinator, _} ->
                    Collect()
            end;
        error ->
            Collect()
    end.

%% @doc The running coordinator, or a new one.
coordinator() ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined -> start_coordinator()
    end.

%% A new coordinator starts serving only once it holds the registered name;
%% when another request registered one first, that one is used.
start_coordinator() ->
    Pid = spawn(fun() ->
        receive start -> coordinate(#{})
        after ?COORDINATOR_START_MS -> ok
        end
    end),
    try register(?MODULE, Pid) of
        true ->
            Pid ! start,
            {ok, Pid}
    catch
        error:badarg ->
            exit(Pid, kill),
            case whereis(?MODULE) of
                Running when is_pid(Running) -> {ok, Running};
                undefined -> error
            end
    end.

%% @doc The coordinator loop. `Collections' maps a key to
%% `{running, Worker, Waiters, MaxAge}' while its collection runs, where
%% `Worker' is the monitor of the collection process, and to
%% `{done, At, MaxAge, Result}' while the result may be reused. Expired
%% results are dropped when the next request arrives.
coordinate(Collections) ->
    receive
        {collect, From, Tag, Key, MaxAge, Collect} ->
            Now = erlang:monotonic_time(millisecond),
            Current = maps:filter(
                fun(_, {done, At, Age, _}) -> Now - At < Age;
                   (_, _) -> true
                end,
                Collections
            ),
            case maps:get(Key, Current, undefined) of
                {done, At, _, Result} when Now - At < MaxAge ->
                    From ! {Tag, {ok, Result}},
                    coordinate(Current);
                {running, Worker, Waiters, Age} ->
                    coordinate(Current#{ Key => {running, Worker, [{From, Tag} | Waiters], Age} });
                _ ->
                    {_, Worker} = spawn_monitor(fun() -> exit({collected, Collect()}) end),
                    coordinate(Current#{ Key => {running, Worker, [{From, Tag}], MaxAge} })
            end;
        {'DOWN', Worker, process, _, Exit} ->
            case [Key || Key := {running, Running, _, _} <- Collections, Running =:= Worker] of
                [Key] ->
                    {running, _, Waiters, MaxAge} = maps:get(Key, Collections),
                    Reply =
                        case Exit of
                            {collected, Result} -> {ok, Result};
                            _ -> failed
                        end,
                    lists:foreach(fun({From, Tag}) -> From ! {Tag, Reply} end, Waiters),
                    coordinate(
                        case Reply of
                            {ok, Collected} when MaxAge > 0 ->
                                Now = erlang:monotonic_time(millisecond),
                                Collections#{ Key => {done, Now, MaxAge, Collected} };
                            _ ->
                                maps:remove(Key, Collections)
                        end
                    );
                [] ->
                    coordinate(Collections)
            end;
        _ ->
            coordinate(Collections)
    end.

%%% ------------------------------------------------------------------
%%% sysfs helpers
%%% ------------------------------------------------------------------

%% @doc Read a file and trim surrounding whitespace.
read_text(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, list_to_binary(string:trim(binary_to_list(Bin)))};
        Error -> Error
    end.

%% @doc A trimmed file value, or `undefined' when it cannot be read.
read_optional(Dir, Name) ->
    case read_text(filename:join(Dir, Name)) of
        {ok, Value} -> Value;
        _ -> undefined
    end.

%% @doc The final path component of a symbolic link's target.
link_name(Path) ->
    case file:read_link(Path) of
        {ok, Link} -> unicode:characters_to_binary(filename:basename(Link));
        _ -> undefined
    end.

%% @doc The loaded module version of a driver.
driver_version(_Root, undefined) ->
    undefined;
driver_version(Root, Driver) ->
    read_optional(
        filename:join([binary_to_list(Root), "module", binary_to_list(Driver)]),
        "version"
    ).

%% @doc The DRM node whose `device' link points at the PCI function.
drm_card(Root, Bdf) ->
    Dir = filename:join(binary_to_list(Root), "class/drm"),
    case file:list_dir(Dir) of
        {ok, Names} ->
            case [Name || Name <- lists:sort(Names), drm_matches(filename:join(Dir, Name), Bdf)] of
                [Name | _] -> list_to_binary(Name);
                [] -> undefined
            end;
        _ -> undefined
    end.

drm_matches(Path, Bdf) ->
    case file:read_link(filename:join(Path, "device")) of
        {ok, Link} -> filename:basename(Link) =:= Bdf;
        _ -> false
    end.

%%% ------------------------------------------------------------------
%%% Value helpers
%%% ------------------------------------------------------------------

%% @doc An integer when the field is an integer, otherwise the text.
number_or_text(undefined) -> undefined;
number_or_text(<<>>) -> undefined;
number_or_text(Value) ->
    try binary_to_integer(Value)
    catch _:_ -> Value
    end.

%% @doc Convert a MiB value to bytes.
mib_to_bytes(Value) ->
    case number_or_text(Value) of
        Number when is_integer(Number) -> Number * 1024 * 1024;
        Other -> Other
    end.

%% @doc A positional CSV field as a binary, or `undefined' when empty.
csv_value(Row, Index) ->
    case lists:nth(Index, Row) of
        "" -> undefined;
        Value -> list_to_binary(Value)
    end.

row_less(A, B) ->
    maps:get(<<"pci-bdf">>, A, <<>>) =< maps:get(<<"pci-bdf">>, B, <<>>).

%% @doc A short, host-neutral description of a failed source.
error_text(Source, Reason) ->
    <<Source/binary, ": unavailable (", (reason_text(Reason))/binary, ")">>.

reason_text({exit_status, Status}) -> <<"exit-status-", (integer_to_binary(Status))/binary>>;
reason_text({spawn_failed, _}) -> <<"spawn-failed">>;
reason_text(Reason) when is_atom(Reason) ->
    binary:replace(atom_to_binary(Reason, utf8), <<"_">>, <<"-">>, [global]);
reason_text(_) -> <<"error">>.

%%% ------------------------------------------------------------------
%%% Tests
%%% ------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% Run `Fun' with a fresh directory that is removed afterwards.
with_test_dir(Fun) ->
    Dir = filename:join(
        filename:absname("_build"),
        "gpu-inventory-test-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after file:del_dir_r(Dir)
    end.

write_file(Path, Contents) ->
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Contents).

symlink(Target, Link) ->
    ok = filelib:ensure_dir(Link),
    ok = file:make_symlink(Target, Link).

%% A sysfs tree with an H100 at 0000:01:00.0, a virtual display adapter at
%% 0000:00:01.0 and a network controller that is not inventoried.
fixture_root(Dir) ->
    Root = filename:join(Dir, "sys"),
    Devices = filename:join(Root, "bus/pci/devices"),
    Pci = fun(Bdf, Files) ->
        lists:foreach(
            fun({Name, Value}) -> write_file(filename:join([Devices, Bdf, Name]), [Value, "\n"]) end,
            Files
        )
    end,
    Pci("0000:01:00.0", [
        {"class", "0x030200"}, {"vendor", "0x10de"}, {"device", "0x2331"},
        {"subsystem_vendor", "0x10de"}, {"subsystem_device", "0x1626"},
        {"revision", "0xa1"}, {"current_link_speed", "32.0 GT/s PCIe"},
        {"current_link_width", "16"}
    ]),
    symlink("../../../bus/pci/drivers/nvidia", filename:join([Devices, "0000:01:00.0", "driver"])),
    symlink("../../../kernel/iommu_groups/7", filename:join([Devices, "0000:01:00.0", "iommu_group"])),
    write_file(filename:join([Root, "module", "nvidia", "version"]), "595.71.05\n"),
    symlink("../../../bus/pci/devices/0000:01:00.0",
        filename:join([Root, "class", "drm", "renderD128", "device"])),
    Pci("0000:00:01.0", [
        {"class", "0x030000"}, {"vendor", "0x1234"}, {"device", "0x1111"},
        {"revision", "0x02"}
    ]),
    Pci("0000:00:02.0", [{"class", "0x020000"}, {"vendor", "0x1af4"}]),
    Root.

write_script(Dir, Name, Body) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, ["#!/bin/sh\n", Body]),
    ok = file:change_mode(Path, 8#755),
    Path.

%% A stand-in `nvidia-smi' answering the inventory and runtime queries for
%% one H100, in `nvidia-smi''s own bus-id format.
fake_nvidia_smi(Dir) ->
    write_script(Dir, "nvidia-smi", nvidia_smi_answers()).

nvidia_smi_answers() ->
    [
        "case \"$1\" in\n",
        "  *temperature.gpu*) echo '0, NVIDIA H100 PCIe, 00000000:01:00.0, 41, 72, 350, 3, 1, 1024, 81559, 345, 345, 1593, P0, [N/A]' ;;\n",
        "  *) echo '0, NVIDIA H100 PCIe, 00000000:01:00.0, 595.71.05, GPU-4f46656c-2135-0fc6-40a0-41b700763229, 81559, 9.0, 96.00.AF.00.01, 5, 16, 350.00, Disabled, Enabled, [N/A]' ;;\n",
        "esac\n"
    ].

%% The stand-in `nvidia-smi' that also records each run in `runs' and
%% answers after `Delay' seconds.
counting_nvidia_smi(Dir, Delay) ->
    write_script(Dir, "counting-nvidia-smi", [
        "echo run >> '", filename:join(Dir, "runs"), "'\n",
        "sleep ", Delay, "\n"
        | nvidia_smi_answers()
    ]).

%% How many times the counting stand-in ran.
runs(Dir) ->
    case file:read_file(filename:join(Dir, "runs")) of
        {ok, Log} -> length(binary:matches(Log, <<"run">>));
        {error, enoent} -> 0
    end.

counting_opts(Dir, Delay, Extra) ->
    maps:merge(
        (fixture_opts(Dir))#{
            <<"gpu-inventory-nvidia-smi-path">> => hb_util:bin(counting_nvidia_smi(Dir, Delay))
        },
        Extra
    ).

fixture_opts(Dir) ->
    #{
        <<"gpu-inventory-root">> => hb_util:bin(fixture_root(Dir)),
        <<"gpu-inventory-nvidia-smi-path">> => hb_util:bin(fake_nvidia_smi(Dir))
    }.

unknown_values_are_dropped_test() ->
    ?assertEqual(
        #{ <<"pci-bdf">> => <<"0000:01:00.0">>, <<"pcie-link">> => #{ <<"width">> => <<"16">> } },
        stable_row(#{
            <<"pci-bdf">> => <<"0000:01:00.0">>,
            <<"driver">> => undefined,
            <<"pcie-link">> => #{ <<"speed">> => undefined, <<"width">> => <<"16">> },
            <<"temperature-c">> => 40
        })
    ),
    ?assertEqual(#{ <<"pci-bdf">> => <<"0000:00:01.0">> },
        stable_row(#{
            <<"pci-bdf">> => <<"0000:00:01.0">>,
            <<"pcie-link">> => #{ <<"speed">> => undefined, <<"width">> => undefined }
        })).

digest_is_stable_test() ->
    Rows = [#{ <<"pci-bdf">> => <<"0000:01:00.0">> }],
    ?assertEqual(digest_for(Rows, topology(Rows)), digest_for(Rows, topology(Rows))).

digest_encoding_is_canonical_test() ->
    Rows = [#{ <<"vendor-id">> => <<"0x10de">>, <<"pci-bdf">> => <<"0000:01:00.0">> }],
    Topology = topology(Rows),
    Expected =
        <<"{\"devices\":[{\"pci-bdf\":\"0000:01:00.0\",\"vendor-id\":\"0x10de\"}],"
          "\"topology\":{\"device-count\":1,\"iommu-groups\":[],"
          "\"pci-bdfs\":[\"0000:01:00.0\"]}}">>,
    ?assertEqual(hb_util:encode(crypto:hash(sha256, Expected)), digest_for(Rows, Topology)).

volatile_fields_are_excluded_test() ->
    Stable = #{ <<"pci-bdf">> => <<"0000:01:00.0">> },
    ?assertEqual(stable_row(Stable#{ <<"temperature-c">> => 70 }),
        stable_row(Stable#{ <<"temperature-c">> => 80 })).

csv_parser_test() ->
    ?assertEqual({ok, [["0", "RTX", "0000:01:00.0"]]},
        parse_csv_rows("0, RTX, 0000:01:00.0\n", 3)),
    ?assertEqual({error, malformed_output}, parse_csv_rows("0, RTX\n", 3)).

bdf_is_normalized_test() ->
    ?assertEqual(<<"0000:01:00.0">>, normalize_bdf(<<"00000000:01:00.0">>)),
    ?assertEqual(<<"0000:3b:00.0">>, normalize_bdf(<<"00000000:3B:00.0">>)),
    ?assertEqual(<<"10000:01:00.0">>, normalize_bdf(<<"00010000:01:00.0">>)),
    ?assertEqual(<<"0000:01:00.0">>, normalize_bdf(<<"0000:01:00.0">>)).

report_merges_nvidia_and_sysfs_rows_test() ->
    with_test_dir(fun(Dir) ->
        {ok, Report} = report(#{}, #{}, fixture_opts(Dir)),
        ?assertMatch(
            #{
                <<"type">> := <<"apus-gpu-inventory">>,
                <<"supported">> := true,
                <<"errors">> := [],
                <<"provenance">> := #{
                    <<"class">> := <<"host-observed">>,
                    <<"sources">> := [<<"nvidia-smi">>, <<"sysfs">>]
                },
                <<"topology">> := #{
                    <<"device-count">> := 2,
                    <<"pci-bdfs">> := [<<"0000:00:01.0">>, <<"0000:01:00.0">>],
                    <<"iommu-groups">> := [<<"7">>]
                }
            },
            Report
        ),
        [Virtual, H100] = maps:get(<<"devices">>, Report),
        ?assertEqual(
            #{
                <<"pci-bdf">> => <<"0000:00:01.0">>,
                <<"class">> => <<"0x030000">>,
                <<"vendor-id">> => <<"0x1234">>,
                <<"device-id">> => <<"0x1111">>,
                <<"revision">> => <<"0x02">>
            },
            Virtual
        ),
        ?assertMatch(
            #{
                <<"pci-bdf">> := <<"0000:01:00.0">>,
                <<"class">> := <<"0x030200">>,
                <<"driver">> := <<"nvidia">>,
                <<"driver-version">> := <<"595.71.05">>,
                <<"drm-card">> := <<"renderD128">>,
                <<"gpu-uuid">> := <<"GPU-4f46656c-2135-0fc6-40a0-41b700763229">>,
                <<"vram-bytes">> := 85520809984,
                <<"pcie-link">> := #{ <<"width">> := <<"16">> }
            },
            H100
        ),
        ?assertNot(maps:is_key(<<"source">>, H100))
    end).

digest_matches_report_test() ->
    with_test_dir(fun(Dir) ->
        Opts = fixture_opts(Dir),
        {ok, Report} = report(#{}, #{}, Opts),
        {ok, Digest} = digest(#{}, #{}, Opts),
        ?assertEqual(
            #{
                <<"type">> => <<"apus-gpu-inventory-digest">>,
                <<"version">> => ?VERSION,
                <<"inventory-digest">> => maps:get(<<"inventory-digest">>, Report),
                <<"provenance-class">> => <<"host-observed">>
            },
            Digest
        ),
        #{ <<"devices">> := Rows, <<"topology">> := Topology } = Report,
        ?assertEqual(maps:get(<<"inventory-digest">>, Report), digest_for(Rows, Topology))
    end).

request_cannot_select_the_root_test() ->
    with_test_dir(fun(Dir) ->
        Root = hb_util:bin(fixture_root(Dir)),
        Empty = hb_util:bin(filename:join(Dir, "empty")),
        Opts = #{
            <<"gpu-inventory-root">> => Empty,
            <<"gpu-inventory-nvidia-smi-path">> => <<"/nonexistent/nvidia-smi">>
        },
        {ok, Report} = report(#{ <<"gpu-inventory-root">> => Root },
            #{ <<"gpu-inventory-root">> => Root }, Opts),
        ?assertMatch(#{ <<"supported">> := false, <<"devices">> := [] }, Report)
    end).

missing_nvidia_smi_is_not_an_error_test() ->
    with_test_dir(fun(Dir) ->
        Opts = #{
            <<"gpu-inventory-root">> => hb_util:bin(fixture_root(Dir)),
            <<"gpu-inventory-nvidia-smi-path">> => <<"/nonexistent/nvidia-smi">>
        },
        {ok, Report} = report(#{}, #{}, Opts),
        ?assertMatch(
            #{ <<"errors">> := [], <<"provenance">> := #{ <<"sources">> := [<<"sysfs">>] } },
            Report
        ),
        {ok, Snapshot} = snapshot(#{}, #{}, Opts),
        ?assertMatch(#{ <<"supported">> := false, <<"errors">> := [] }, Snapshot)
    end).

failing_nvidia_smi_is_reported_test() ->
    with_test_dir(fun(Dir) ->
        Failing = write_script(Dir, "failing-nvidia-smi", "exit 9\n"),
        Slow = write_script(Dir, "slow-nvidia-smi", "exec sleep 5\n"),
        Root = hb_util:bin(fixture_root(Dir)),
        {ok, Failed} = report(#{}, #{}, #{
            <<"gpu-inventory-root">> => Root,
            <<"gpu-inventory-nvidia-smi-path">> => hb_util:bin(Failing)
        }),
        ?assertEqual([<<"nvidia-smi: unavailable (exit-status-9)">>],
            maps:get(<<"errors">>, Failed)),
        {ok, TimedOut} = snapshot(#{}, #{}, #{
            <<"gpu-inventory-nvidia-smi-path">> => hb_util:bin(Slow),
            <<"gpu-inventory-nvidia-smi-timeout">> => 200
        }),
        ?assertEqual([<<"nvidia-smi: unavailable (timeout)">>],
            maps:get(<<"errors">>, TimedOut))
    end).

inventory_report_is_reused_test() ->
    with_test_dir(fun(Dir) ->
        Opts = counting_opts(Dir, "0", #{}),
        {ok, First} = report(#{}, #{}, Opts),
        {ok, Second} = report(#{}, #{}, Opts),
        {ok, Digest} = digest(#{}, #{}, Opts),
        ?assertEqual(1, runs(Dir)),
        ?assertEqual(First, Second),
        ?assertEqual(maps:get(<<"inventory-digest">>, First),
            maps:get(<<"inventory-digest">>, Digest)),
        %% Snapshots are never reused.
        {ok, _} = snapshot(#{}, #{}, Opts),
        {ok, _} = snapshot(#{}, #{}, Opts),
        ?assertEqual(3, runs(Dir))
    end).

inventory_reuse_follows_the_cache_option_test() ->
    with_test_dir(fun(Dir) ->
        Uncached = counting_opts(Dir, "0", #{ <<"gpu-inventory-cache-ms">> => 0 }),
        {ok, _} = report(#{}, #{}, Uncached),
        {ok, _} = report(#{}, #{}, Uncached),
        ?assertEqual(2, runs(Dir)),
        Short = Uncached#{ <<"gpu-inventory-cache-ms">> => <<"200">> },
        {ok, _} = report(#{}, #{}, Short),
        {ok, _} = report(#{}, #{}, Short),
        ?assertEqual(3, runs(Dir)),
        timer:sleep(300),
        {ok, _} = report(#{}, #{}, Short),
        ?assertEqual(4, runs(Dir)),
        ?assertEqual(5000, cache_ms(#{ <<"gpu-inventory-cache-ms">> => -1 })),
        ?assertEqual(5000, cache_ms(#{ <<"gpu-inventory-cache-ms">> => <<"soon">> }))
    end).

concurrent_requests_share_one_run_test() ->
    with_test_dir(fun(Dir) ->
        Opts = counting_opts(Dir, "0.5", #{ <<"gpu-inventory-cache-ms">> => 0 }),
        %% Five requests at once; each returns `{ok, Result}'.
        Concurrently = fun(Call) ->
            Self = self(),
            Pids = [spawn(fun() -> Self ! {self(), Call()} end) || _ <- lists:seq(1, 5)],
            [receive {Pid, {ok, Result}} -> Result after 10000 -> timeout end || Pid <- Pids]
        end,
        Reports = Concurrently(fun() -> report(#{}, #{}, Opts) end),
        ?assertEqual(1, runs(Dir)),
        ?assertMatch([#{ <<"type">> := <<"apus-gpu-inventory">> }], lists:usort(Reports)),
        Snapshots = Concurrently(fun() -> snapshot(#{}, #{}, Opts) end),
        ?assertEqual(2, runs(Dir)),
        ?assertMatch([#{ <<"type">> := <<"apus-gpu-runtime-snapshot">> }],
            lists:usort(Snapshots))
    end).

snapshot_reads_runtime_fields_test() ->
    with_test_dir(fun(Dir) ->
        {ok, Snapshot} = snapshot(#{}, #{}, fixture_opts(Dir)),
        ?assertMatch(
            #{
                <<"type">> := <<"apus-gpu-runtime-snapshot">>,
                <<"supported">> := true,
                <<"provenance">> := #{ <<"class">> := <<"runtime-observed">> },
                <<"devices">> := [#{
                    <<"pci-bdf">> := <<"0000:01:00.0">>,
                    <<"temperature-c">> := 41,
                    <<"memory-used-mib">> := 1024,
                    <<"pstate">> := <<"P0">>,
                    <<"fan-speed-percent">> := <<"[N/A]">>
                }]
            },
            Snapshot
        )
    end).

-endif.
