%%% @doc NVIDIA confidential-computing GPU attestation.
%%%
%%% `sev_gpu@1.0' asks the node's NVIDIA GPUs for attestation evidence bound
%%% to a caller-supplied nonce, verifies the evidence locally with NVIDIA's
%%% attestation SDK (NVAT), and reports `verified' only when the SDK accepts
%%% the evidence and every GPU claim set passes the device's claims rule.
%%%
%%% The SDK is reached through the `dev_sev_gpu_nif' wrapper module and its
%%% shared library, both shipped in the implementation archive. When they are
%%% not available the device runs the operator-configured `nvattest'
%%% executable directly, without a shell. Executable paths, limits and the
%%% backend choice are node options: a request supplies only the nonce and
%%% the evidence to verify.
-module(dev_sev_gpu).
-implements(<<"sev_gpu@1.0">>).
-specification("docs/spec/sev_gpu.md").
-export([info/1, generate/3, verify/3]).
-include_lib("hb/include/hb.hrl").

%% The module that owns the NVAT NIF. It is not a device module, so Device
%% Forge does not rename it and the library's `ERL_NIF_INIT' name matches.
-define(NIF_MODULE, dev_sev_gpu_nif).
-define(NIF_FILE, "dev_sev_gpu_nif").
%% Archive resources may extract below this directory of the implementation
%% directory.
-define(NATIVE_SUBDIR, "dev_sev_gpu").

-define(DEFAULT_BACKEND, <<"auto">>).
-define(DEFAULT_NVATTEST_PATH, <<"/usr/bin/nvattest">>).
-define(DEFAULT_NVATTEST_TIMEOUT_MS, 60000).
-define(DEFAULT_SCRATCH_DIR, <<"/tmp">>).
%% Upper bound on the bytes read from one `nvattest' run.
-define(MAX_NVATTEST_OUTPUT, 16777216).
%% NVIDIA GPU attestation reports bind a 32-byte nonce.
-define(NONCE_HEX_LENGTH, 64).

%% Claims each GPU claim set must carry, with the exact value shown, before
%% `verified' can be true. NVAT emits all of them in its GPU claims (claim
%% versions 3.0 and 4.0). `eat_nonce' is compared with the nonce separately.
-define(REQUIRED_CLAIMS, [
    {<<"measres">>, <<"success">>},
    {<<"x-nvidia-gpu-arch-check">>, true},
    {<<"x-nvidia-gpu-attestation-report-parsed">>, true},
    {<<"x-nvidia-gpu-attestation-report-nonce-match">>, true},
    {<<"x-nvidia-gpu-attestation-report-signature-verified">>, true},
    {<<"x-nvidia-gpu-attestation-report-cert-chain-fwid-match">>, true}
]).

%% @doc Return the keys this device resolves.
-spec info(map()) -> #{ exports := [binary()] }.
info(_Opts) ->
    #{ exports => [<<"generate">>, <<"verify">>] }.

%% @doc Collect GPU evidence for the request's `nonce', verify it locally and
%% return the result as a JSON object with `nonce', `evidences', `claims',
%% `eat' and `verified'.
-spec generate(
    #{ _ => _ },
    #{ nonce => binary(), _ => _ },
    map()
) -> {ok, binary()} | {error, term()}.
generate(_Base, Req, Opts) ->
    maybe
        {ok, Nonce} ?= request_nonce(Req, Opts),
        {ok, Backend} ?= backend(Opts),
        {ok, Result} ?= collect(Backend, Nonce, Opts),
        {ok, hb_json:encode(Result)}
    end.

%% @doc Verify GPU evidence produced by `generate' and return the binary
%% `true' or `false'. The evidence is read from `body' or `evidences'. An
%% optional `nonce' must equal the nonce the evidence was collected for.
-spec verify(
    #{ _ => _ },
    #{ body => _, evidences => _, nonce => binary(), _ => _ },
    map()
) -> {ok, binary()} | {error, term()}.
verify(_Base, Req, Opts) ->
    maybe
        {ok, Evidences} ?= request_evidences(Req, Opts),
        {ok, Nonce} ?= evidence_nonce(Evidences),
        {ok, Expected} ?= expected_nonce(Req, Opts),
        {ok, Backend} ?= backend(Opts),
        {ok, Verified} ?=
            case Expected =:= undefined orelse same_hex(Expected, Nonce) of
                true -> check(Backend, Evidences, Nonce, Opts);
                false -> {ok, false}
            end,
        {ok, atom_to_binary(Verified, utf8)}
    end.

%%% ------------------------------------------------------------------
%%% Request parsing
%%% ------------------------------------------------------------------

%% @doc Read the required nonce. The device never substitutes a value: a
%% report for a nonce the caller did not choose would be replayable.
request_nonce(Req, Opts) ->
    case hb_ao:get(<<"nonce">>, Req, undefined, Opts) of
        undefined -> {error, nonce_required};
        Nonce ->
            case valid_nonce(Nonce) of
                true -> {ok, Nonce};
                false -> {error, invalid_nonce}
            end
    end.

%% @doc Read the optional nonce a verifier expects the evidence to carry.
expected_nonce(Req, Opts) ->
    case hb_ao:get(<<"nonce">>, Req, undefined, Opts) of
        undefined -> {ok, undefined};
        Nonce ->
            case valid_nonce(Nonce) of
                true -> {ok, Nonce};
                false -> {error, invalid_nonce}
            end
    end.

%% @doc A nonce is exactly 64 hexadecimal characters (32 bytes).
valid_nonce(Nonce) when is_binary(Nonce), byte_size(Nonce) =:= ?NONCE_HEX_LENGTH ->
    lists:all(fun is_hex/1, binary_to_list(Nonce));
valid_nonce(_) ->
    false.

is_hex(C) when C >= $0, C =< $9 -> true;
is_hex(C) when C >= $a, C =< $f -> true;
is_hex(C) when C >= $A, C =< $F -> true;
is_hex(_) -> false.

%% @doc Read the evidence list to verify from `body' (a JSON array, or a
%% JSON object with an `evidences' array such as a `generate' result), or
%% from an `evidences' key; Erlang terms of the same shape are accepted.
request_evidences(Req, Opts) ->
    case first_defined([
        hb_ao:get(<<"body">>, Req, undefined, Opts),
        hb_ao:get(<<"evidences">>, Req, undefined, Opts)
    ]) of
        undefined -> {error, evidence_required};
        Raw -> evidences_from(hb_cache:ensure_all_loaded(Raw, Opts))
    end.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([not_found | Rest]) -> first_defined(Rest);
first_defined([Value | _]) -> Value.

evidences_from(Bin) when is_binary(Bin) ->
    try hb_json:decode(Bin) of
        Decoded -> evidences_from_term(Decoded)
    catch
        _:_ -> {error, invalid_evidence}
    end;
evidences_from(Term) ->
    evidences_from_term(Term).

evidences_from_term(#{ <<"evidences">> := Evidences }) ->
    evidences_from_term(Evidences);
evidences_from_term([_ | _] = Evidences) ->
    case lists:all(fun is_evidence/1, Evidences) andalso encodable(Evidences) of
        true -> {ok, Evidences};
        false -> {error, invalid_evidence}
    end;
evidences_from_term(_) ->
    {error, invalid_evidence}.

%% @doc An NVAT GPU evidence entry carries these four UTF-8 string fields.
is_evidence(Evidence) when is_map(Evidence) ->
    lists:all(
        fun(Key) -> is_text(maps:get(Key, Evidence, undefined)) end,
        [<<"arch">>, <<"nonce">>, <<"evidence">>, <<"certificate">>]
    );
is_evidence(_) ->
    false.

is_text(Value) when is_binary(Value) ->
    unicode:characters_to_binary(Value) =:= Value;
is_text(_) ->
    false.

%% @doc Evidence reaches NVAT as JSON, so it must encode as JSON.
encodable(Term) ->
    try hb_json:encode(Term) of
        _ -> true
    catch
        _:_ -> false
    end.

%% @doc Every evidence entry must carry the same valid nonce.
evidence_nonce([First | _] = Evidences) ->
    Nonce = maps:get(<<"nonce">>, First),
    case valid_nonce(Nonce) andalso evidence_nonces_match(Evidences, Nonce) of
        true -> {ok, Nonce};
        false -> {error, invalid_evidence}
    end.

%%% ------------------------------------------------------------------
%%% Backends
%%% ------------------------------------------------------------------

%% @doc The backend selected by the `sev-gpu-backend' node option.
backend(Opts) ->
    case option_bin(<<"sev-gpu-backend">>, ?DEFAULT_BACKEND, Opts) of
        <<"auto">> -> {ok, auto};
        <<"nif">> -> {ok, nif};
        <<"nvattest">> -> {ok, nvattest};
        _ -> {error, invalid_backend}
    end.

%% @doc Collect and locally verify evidence with the selected backend. In
%% `auto' mode `nvattest' runs only when the NIF is not available; an NVAT
%% error reported by a loaded NIF is final.
collect(auto, Nonce, Opts) ->
    case collect(nif, Nonce, Opts) of
        {error, nif_unavailable} -> collect(nvattest, Nonce, Opts);
        Result -> Result
    end;
collect(nif, Nonce, _Opts) ->
    case nif_call(collect_evidence, [Nonce]) of
        {ok, JSON} ->
            Report = decode_object(JSON),
            {ok,
                result(
                    maps:get(<<"evidences">>, Report, []),
                    maps:get(<<"claims">>, Report, []),
                    maps:get(<<"eat">>, Report, null),
                    maps:get(<<"verified">>, Report, false),
                    Nonce
                )
            };
        {error, nif_unavailable} = Error -> Error;
        {error, Reason} -> {error, {nvat_error, Reason}}
    end;
collect(nvattest, Nonce, Opts) ->
    maybe
        {ok, Path} ?= nvattest_path(Opts),
        {ok, Attest} ?= nvattest(Path, [<<"attest">>, <<"--nonce">>, Nonce], Opts),
        {ok, Collected} ?=
            nvattest(Path, [<<"collect-evidence">>, <<"--nonce">>, Nonce], Opts),
        {ok,
            result(
                maps:get(<<"evidences">>, Collected, []),
                maps:get(<<"claims">>, Attest, []),
                maps:get(<<"detached_eat">>, Attest, null),
                maps:get(<<"result_code">>, Attest, undefined) =:= 0,
                Nonce
            )
        }
    end.

%% @doc Verify existing evidence with the selected backend.
check(auto, Evidences, Nonce, Opts) ->
    case check(nif, Evidences, Nonce, Opts) of
        {error, nif_unavailable} -> check(nvattest, Evidences, Nonce, Opts);
        Result -> Result
    end;
check(nif, Evidences, Nonce, Opts) ->
    Request =
        hb_json:encode(#{
            <<"nonce">> => Nonce,
            <<"evidences">> => Evidences,
            <<"scratch-dir">> => scratch_dir(Opts)
        }),
    case nif_call(verify_evidence, [Request]) of
        {ok, JSON} ->
            Report = decode_object(JSON),
            {ok,
                maps:get(<<"verified">>, Report, false) =:= true andalso
                    claims_verified(as_list(maps:get(<<"claims">>, Report, [])), Nonce)
            };
        {error, nif_unavailable} = Error -> Error;
        {error, Reason} -> {error, {nvat_error, Reason}}
    end;
check(nvattest, Evidences, Nonce, Opts) ->
    maybe
        {ok, Path} ?= nvattest_path(Opts),
        {ok, Attest} ?=
            with_scratch_file(
                hb_json:encode(Evidences),
                Opts,
                fun(File) ->
                    nvattest(
                        Path,
                        [
                            <<"attest">>,
                            <<"--gpu-evidence-source">>, <<"file">>,
                            <<"--gpu-evidence-file">>, hb_util:bin(File),
                            <<"--nonce">>, Nonce
                        ],
                        Opts
                    )
                end
            ),
        {ok,
            maps:get(<<"result_code">>, Attest, undefined) =:= 0 andalso
                claims_verified(as_list(maps:get(<<"claims">>, Attest, [])), Nonce)
        }
    end.

%%% ------------------------------------------------------------------
%%% Verification rule
%%% ------------------------------------------------------------------

%% @doc Build a `generate' result. `BackendAccepted' is NVAT's own verdict;
%% `verified' also requires the evidence nonces and the claims rule to hold.
result(Evidences0, Claims0, Eat, BackendAccepted, Nonce) ->
    Evidences = as_list(Evidences0),
    Claims = as_list(Claims0),
    #{
        <<"nonce">> => Nonce,
        <<"evidences">> => Evidences,
        <<"claims">> => Claims,
        <<"eat">> => detached_eat(Eat),
        <<"verified">> =>
            BackendAccepted =:= true
                andalso evidence_nonces_match(Evidences, Nonce)
                andalso claims_verified(Claims, Nonce)
    }.

%% @doc NVAT returns one claim set and one evidence entry per GPU as JSON
%% arrays; a lone object counts as a list of one and anything else as none.
as_list(List) when is_list(List) -> List;
as_list(Map) when is_map(Map), map_size(Map) > 0 -> [Map];
as_list(_) -> [].

%% @doc The detached EAT is a non-empty JSON array; otherwise it is `null'.
detached_eat([_ | _] = Eat) -> Eat;
detached_eat(_) -> null.

%% @doc True when the list is non-empty and every entry carries `Nonce'.
evidence_nonces_match([_ | _] = Evidences, Nonce) ->
    lists:all(
        fun(Evidence) ->
            is_map(Evidence) andalso
                same_hex(maps:get(<<"nonce">>, Evidence, undefined), Nonce)
        end,
        Evidences
    );
evidence_nonces_match(_, _Nonce) ->
    false.

%% @doc True when the list is non-empty and every claim set passes.
claims_verified([_ | _] = ClaimSets, Nonce) ->
    lists:all(fun(Claims) -> claim_set_verified(Claims, Nonce) end, ClaimSets);
claims_verified(_, _Nonce) ->
    false.

claim_set_verified(Claims, Nonce) when is_map(Claims) ->
    lists:all(
        fun({Key, Required}) -> maps:get(Key, Claims, undefined) =:= Required end,
        ?REQUIRED_CLAIMS
    ) andalso same_hex(maps:get(<<"eat_nonce">>, Claims, undefined), Nonce);
claim_set_verified(_, _Nonce) ->
    false.

%% @doc Compare two hex strings without regard to letter case.
same_hex(A, B) when is_binary(A), is_binary(B) ->
    hb_util:to_lower(A) =:= hb_util:to_lower(B);
same_hex(_, _) ->
    false.

%%% ------------------------------------------------------------------
%%% NIF backend
%%% ------------------------------------------------------------------

%% @doc Call a function of the NIF wrapper, loading it on first use.
nif_call(Function, Args) ->
    case nif() of
        ok ->
            try apply(?NIF_MODULE, Function, Args)
            catch
                error:not_loaded -> {error, nif_unavailable};
                error:{not_loaded, _} -> {error, nif_unavailable};
                error:undef -> {error, nif_unavailable}
            end;
        {error, _} ->
            {error, nif_unavailable}
    end.

%% @doc Make sure the wrapper module and its NVAT library are loaded.
nif() ->
    maybe
        {ok, Dir} ?= native_dir(),
        ok ?= load_wrapper(Dir),
        load_library(Dir)
    end.

%% A wrapper module stays loaded for the life of the node. When it was
%% loaded from another directory (for example from an earlier implementation
%% archive), the device keeps using it and reports the difference once: the
%% module and its library are replaced by restarting the node.
load_wrapper(Dir) ->
    Path = filename:join(Dir, ?NIF_FILE),
    case code:is_loaded(?NIF_MODULE) of
        {file, Loaded} ->
            case same_beam(Loaded, Path) of
                true -> ok;
                false -> report_once(wrapper_origin, "sev_gpu@1.0: using ~ts.beam; "
                    "restart the node to load ~ts.beam~n", [loaded_path(Loaded), Path])
            end;
        false ->
            case code:load_abs(Path) of
                {module, ?NIF_MODULE} -> ok;
                {error, Reason} -> report_nif_failure(Path, Reason)
            end
    end.

%% @doc Whether the loaded object file is `<Path>.beam'.
same_beam(Loaded, Path) when is_list(Loaded); is_binary(Loaded) ->
    filename:absname(filename:rootname(Loaded)) =:= filename:absname(Path);
same_beam(_Loaded, _Path) ->
    false.

loaded_path(Loaded) when is_list(Loaded); is_binary(Loaded) ->
    filename:rootname(Loaded);
loaded_path(Loaded) ->
    io_lib:format("~p", [Loaded]).

load_library(Dir) ->
    case catch ?NIF_MODULE:loaded() of
        true -> ok;
        _ ->
            Path = filename:join(Dir, ?NIF_FILE),
            case ?NIF_MODULE:load(Path) of
                ok -> ok;
                {error, Reason} -> report_nif_failure(Path, Reason)
            end
    end.

%% @doc A wrapper that exists but does not load is an operator problem (for
%% example a missing NVAT library). Report it once per node on standard error.
report_nif_failure(Path, Reason) ->
    ?event(sev_gpu, {nif_load_failed, {path, Path}, {reason, Reason}}),
    report_once(nif_failure, "sev_gpu@1.0: NVAT NIF not loaded from ~ts: ~p~n",
        [Path, Reason]),
    {error, {nif_load_failed, Reason}}.

%% @doc Print a message on standard error the first time `Tag' is reported.
report_once(Tag, Format, Args) ->
    Key = {?MODULE, reported, Tag},
    case persistent_term:get(Key, false) of
        true -> ok;
        false ->
            persistent_term:put(Key, true),
            io:format(standard_error, Format, Args)
    end.

%% @doc The first directory that holds the wrapper module: the implementation
%% directory where Device Forge extracts the archive's `priv' resources (or
%% its `dev_sev_gpu/' subdirectory), then `src/dev_sev_gpu/priv' below the
%% working directory of a source checkout.
native_dir() ->
    ImplDirs =
        try hb_device_archive:implementation_dir(?MODULE) of
            ImplDir -> [filename:join(ImplDir, ?NATIVE_SUBDIR), ImplDir]
        catch
            _:_ -> []
        end,
    Candidates = ImplDirs ++ [filename:absname(filename:join(["src", ?NATIVE_SUBDIR, "priv"]))],
    case [Dir || Dir <- Candidates, filelib:is_regular(filename:join(Dir, ?NIF_FILE ++ ".beam"))] of
        [Dir | _] -> {ok, Dir};
        [] -> {error, wrapper_missing}
    end.

%%% ------------------------------------------------------------------
%%% nvattest backend
%%% ------------------------------------------------------------------

%% @doc The configured `nvattest' path. It must be an absolute path to an
%% existing regular file; the device never searches `PATH'.
nvattest_path(Opts) ->
    Path = hb_util:list(
        option_bin(<<"sev-gpu-nvattest-path">>, ?DEFAULT_NVATTEST_PATH, Opts)
    ),
    case filename:pathtype(Path) =:= absolute andalso filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> {error, nvattest_not_found}
    end.

%% @doc Run one `nvattest' subcommand with JSON output and decode the result.
%% The exit status is not used: NVAT reports its outcome in `result_code'.
nvattest(Path, Args, Opts) ->
    FullArgs = [<<"--format">>, <<"json">> | Args],
    case run(Path, FullArgs, [{"NVAT_LOG_LEVEL", "off"}], timeout(Opts)) of
        {ok, _Status, Output} ->
            case decode_object(Output) of
                Decoded when map_size(Decoded) > 0 -> {ok, Decoded};
                _ -> {error, nvattest_invalid_response}
            end;
        {error, timeout} -> {error, nvattest_timeout};
        {error, output_too_large} -> {error, nvattest_invalid_response};
        {error, {spawn_failed, Reason}} -> {error, {nvattest_spawn_failed, Reason}}
    end.

%% @doc Run an executable without a shell and collect its standard output
%% for at most `Timeout' milliseconds. On timeout the device closes the port,
%% which closes the process's standard input and output; the process itself
%% ends when it next writes output or exits on its own.
run(Path, Args, Env, Timeout) ->
    PortOpts = [
        {args, [hb_util:list(Arg) || Arg <- Args]},
        {env, Env},
        binary,
        exit_status,
        use_stdio,
        hide
    ],
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
        {Port, {data, Data}} when Size + byte_size(Data) =< ?MAX_NVATTEST_OUTPUT ->
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

%% @doc Write `Contents' to a fresh file in the scratch directory, call `Fun'
%% with its path and delete the file afterwards.
with_scratch_file(Contents, Opts, Fun) ->
    Name = "sev-gpu-evidence-" ++
        hb_util:list(hb_util:to_hex(crypto:strong_rand_bytes(16))) ++ ".json",
    Path = filename:join(hb_util:list(scratch_dir(Opts)), Name),
    case file:write_file(Path, Contents, [exclusive]) of
        ok ->
            try Fun(Path)
            after file:delete(Path)
            end;
        {error, Reason} ->
            {error, {scratch_unavailable, Reason}}
    end.

%%% ------------------------------------------------------------------
%%% Helpers
%%% ------------------------------------------------------------------

scratch_dir(Opts) ->
    case option_bin(<<"sev-gpu-scratch-dir">>, ?DEFAULT_SCRATCH_DIR, Opts) of
        <<>> -> ?DEFAULT_SCRATCH_DIR;
        Dir -> Dir
    end.

timeout(Opts) ->
    case hb_opts:get(<<"sev-gpu-nvattest-timeout">>, ?DEFAULT_NVATTEST_TIMEOUT_MS, Opts) of
        Timeout when is_integer(Timeout), Timeout > 0 -> Timeout;
        Bin when is_binary(Bin) ->
            try binary_to_integer(Bin) of
                Timeout when Timeout > 0 -> Timeout;
                _ -> ?DEFAULT_NVATTEST_TIMEOUT_MS
            catch _:_ -> ?DEFAULT_NVATTEST_TIMEOUT_MS
            end;
        _ -> ?DEFAULT_NVATTEST_TIMEOUT_MS
    end.

%% @doc Read a node option as a binary; non-text values read as `<<>>'.
option_bin(Key, Default, Opts) ->
    case hb_opts:get(Key, Default, Opts) of
        Value when is_binary(Value) -> Value;
        Value when is_atom(Value) -> atom_to_binary(Value, utf8);
        Value when is_list(Value) ->
            try unicode:characters_to_binary(Value) of
                Bin when is_binary(Bin) -> Bin;
                _ -> <<>>
            catch _:_ -> <<>>
            end;
        _ -> <<>>
    end.

%% @doc Decode a JSON object, or return an empty map.
decode_object(JSON) when is_binary(JSON) ->
    try hb_json:decode(string:trim(JSON)) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    catch
        _:_ -> #{}
    end;
decode_object(_) ->
    #{}.

%%% ------------------------------------------------------------------
%%% Tests
%%% ------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(TEST_NONCE,
    <<"da4a06c3604a5fac8aa0b4aaf5a6354cdd0dc7c193299bc3464f30b5cbfb931a">>).

%% A claim set as NVAT reports it for a healthy H100 (claims version 3.0),
%% with certificate-chain details omitted.
genuine_claims(Nonce) ->
    #{
        <<"dbgstat">> => <<"disabled">>,
        <<"eat_nonce">> => Nonce,
        <<"hwmodel">> => <<"GH100 A01 GSP BROM">>,
        <<"measres">> => <<"success">>,
        <<"oemid">> => <<"5703">>,
        <<"secboot">> => true,
        <<"ueid">> => <<"546845106352401073416089131505540298088461287884">>,
        <<"x-nvidia-device-type">> => <<"gpu">>,
        <<"x-nvidia-gpu-arch-check">> => true,
        <<"x-nvidia-gpu-attestation-report-cert-chain-fwid-match">> => true,
        <<"x-nvidia-gpu-attestation-report-nonce-match">> => true,
        <<"x-nvidia-gpu-attestation-report-parsed">> => true,
        <<"x-nvidia-gpu-attestation-report-signature-verified">> => true,
        <<"x-nvidia-gpu-claims-version">> => <<"3.0">>,
        <<"x-nvidia-gpu-driver-rim-fetched">> => true,
        <<"x-nvidia-gpu-driver-rim-measurements-available">> => true,
        <<"x-nvidia-gpu-driver-rim-signature-verified">> => true,
        <<"x-nvidia-gpu-driver-rim-version-match">> => true,
        <<"x-nvidia-gpu-driver-version">> => <<"595.71.05">>,
        <<"x-nvidia-gpu-vbios-index-no-conflict">> => true,
        <<"x-nvidia-gpu-vbios-rim-fetched">> => true,
        <<"x-nvidia-gpu-vbios-rim-measurements-available">> => true,
        <<"x-nvidia-gpu-vbios-rim-signature-verified">> => true,
        <<"x-nvidia-gpu-vbios-rim-version-match">> => true,
        <<"x-nvidia-gpu-vbios-version">> => <<"96.00.AF.00.01">>,
        <<"x-nvidia-mismatch-measurement-records">> => null
    }.

test_evidence(Nonce) ->
    #{
        <<"arch">> => <<"HOPPER">>,
        <<"nonce">> => Nonce,
        <<"evidence">> => <<"ZXZpZGVuY2U=">>,
        <<"certificate">> => <<"Y2VydGlmaWNhdGU=">>
    }.

%% Options that force the `nvattest' backend through a stand-in executable.
cli_opts(Script, Extra) ->
    maps:merge(
        #{
            <<"sev-gpu-backend">> => <<"nvattest">>,
            <<"sev-gpu-nvattest-path">> => hb_util:bin(Script),
            <<"sev-gpu-nvattest-timeout">> => 5000
        },
        Extra
    ).

%% Run `Fun' with a fresh directory that is removed afterwards.
with_test_dir(Fun) ->
    Dir = filename:join(
        filename:absname("_build"),
        "sev-gpu-test-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    try Fun(Dir)
    after file:del_dir_r(Dir)
    end.

write_script(Dir, Name, Body) ->
    Path = filename:join(Dir, Name),
    ok = file:write_file(Path, ["#!/bin/sh\n", Body]),
    ok = file:change_mode(Path, 8#755),
    Path.

%% A stand-in `nvattest' that answers like NVAT for the nonce it is given.
%% `ResultCode' is reported by `attest'. When `--gpu-evidence-file' is given
%% the script records the path and requires the file to hold the nonce.
fake_nvattest(Dir, ResultCode) ->
    Claims = hb_json:encode(#{
        <<"claims">> => [genuine_claims(<<"%s">>)],
        <<"detached_eat">> => [[<<"JWT">>, <<"token">>], #{ <<"GPU-0">> => <<"token">> }],
        <<"result_code">> => ResultCode,
        <<"result_message">> => <<"Ok">>
    }),
    Evidence = hb_json:encode(#{
        <<"evidences">> => [test_evidence(<<"%s">>)],
        <<"result_code">> => 0,
        <<"result_message">> => <<"Ok">>
    }),
    Log = filename:join(Dir, "evidence-file"),
    write_script(Dir, "nvattest", [
        "cmd=\"\"; nonce=\"\"; file=\"\"\n",
        "while [ $# -gt 0 ]; do\n",
        "  case \"$1\" in\n",
        "    attest|collect-evidence) cmd=\"$1\" ;;\n",
        "    --nonce) shift; nonce=\"$1\" ;;\n",
        "    --gpu-evidence-file) shift; file=\"$1\" ;;\n",
        "  esac\n",
        "  shift\n",
        "done\n",
        "if [ -n \"$file\" ]; then\n",
        "  echo \"$file\" > '", Log, "'\n",
        "  grep -q \"$nonce\" \"$file\" || { echo '{\"result_code\":1}'; exit 1; }\n",
        "fi\n",
        "if [ \"$cmd\" = collect-evidence ]; then\n",
        "  printf '", Evidence, "' \"$nonce\"\n",
        "else\n",
        "  printf '", Claims, "' \"$nonce\"\n",
        "fi\n"
    ]).

decoded(Result) ->
    {ok, JSON} = Result,
    hb_json:decode(JSON).

nonce_is_required_test() ->
    ?assertEqual({error, nonce_required}, generate(#{}, #{}, #{})),
    ?assertEqual({error, nonce_required}, generate(#{}, #{<<"other">> => 1}, #{})).

invalid_nonce_is_rejected_test() ->
    ?assertEqual({error, invalid_nonce}, generate(#{}, #{nonce => <<"not-hex">>}, #{})),
    ?assertEqual({error, invalid_nonce}, generate(#{}, #{nonce => <<>>}, #{})),
    Short = binary:part(?TEST_NONCE, 0, 62),
    ?assertEqual({error, invalid_nonce}, generate(#{}, #{nonce => Short}, #{})),
    ?assertEqual({error, invalid_nonce},
        generate(#{}, #{nonce => <<?TEST_NONCE/binary, "00">>}, #{})),
    NonHex = <<"zz", (binary:part(?TEST_NONCE, 2, 62))/binary>>,
    ?assertEqual({error, invalid_nonce}, generate(#{}, #{nonce => NonHex}, #{})),
    ?assert(valid_nonce(string:uppercase(?TEST_NONCE))).

genuine_claims_pass_test() ->
    ?assert(claims_verified([genuine_claims(?TEST_NONCE)], ?TEST_NONCE)),
    %% NVAT reports `eat_nonce' in lower case; the comparison ignores case.
    ?assert(claims_verified([genuine_claims(?TEST_NONCE)],
        string:uppercase(?TEST_NONCE))).

every_required_claim_is_enforced_test() ->
    Claims = genuine_claims(?TEST_NONCE),
    lists:foreach(
        fun({Key, _Required}) ->
            ?assertNot(claims_verified([Claims#{ Key => false }], ?TEST_NONCE)),
            ?assertNot(claims_verified([maps:remove(Key, Claims)], ?TEST_NONCE))
        end,
        ?REQUIRED_CLAIMS
    ),
    ?assertNot(claims_verified([Claims#{ <<"measres">> => <<"fail">> }], ?TEST_NONCE)).

all_claim_sets_must_pass_test() ->
    Good = genuine_claims(?TEST_NONCE),
    Bad = Good#{
        <<"x-nvidia-gpu-attestation-report-signature-verified">> => false
    },
    ?assert(claims_verified([Good, Good], ?TEST_NONCE)),
    ?assertNot(claims_verified([Good, Bad], ?TEST_NONCE)),
    ?assertNot(claims_verified([Bad, Good], ?TEST_NONCE)),
    ?assertNot(claims_verified([], ?TEST_NONCE)),
    ?assertNot(claims_verified(#{}, ?TEST_NONCE)),
    ?assertNot(claims_verified([not_a_map], ?TEST_NONCE)).

claims_must_carry_the_nonce_test() ->
    Other = binary:copy(<<"ab">>, 32),
    ?assertNot(claims_verified([genuine_claims(Other)], ?TEST_NONCE)),
    ?assertNot(claims_verified(
        [maps:remove(<<"eat_nonce">>, genuine_claims(?TEST_NONCE))], ?TEST_NONCE)).

result_requires_backend_evidence_and_claims_test() ->
    Evidence = [test_evidence(?TEST_NONCE)],
    Claims = [genuine_claims(?TEST_NONCE)],
    Eat = [[<<"JWT">>, <<"token">>]],
    ?assertMatch(#{ <<"verified">> := true, <<"nonce">> := ?TEST_NONCE },
        result(Evidence, Claims, Eat, true, ?TEST_NONCE)),
    ?assertMatch(#{ <<"verified">> := false },
        result(Evidence, Claims, Eat, false, ?TEST_NONCE)),
    ?assertMatch(#{ <<"verified">> := false },
        result([], Claims, Eat, true, ?TEST_NONCE)),
    Stale = [test_evidence(binary:copy(<<"cd">>, 32))],
    ?assertMatch(#{ <<"verified">> := false },
        result(Stale, Claims, Eat, true, ?TEST_NONCE)),
    ?assertMatch(#{ <<"claims">> := [], <<"evidences">> := [], <<"eat">> := null },
        result(null, #{}, #{}, false, ?TEST_NONCE)).

backend_option_is_validated_test() ->
    ?assertEqual({error, invalid_backend},
        generate(#{}, #{nonce => ?TEST_NONCE},
            #{ <<"sev-gpu-backend">> => <<"shell">> })).

missing_nvattest_is_reported_test() ->
    Missing = cli_opts("/nonexistent/nvattest", #{}),
    ?assertEqual({error, nvattest_not_found},
        generate(#{}, #{nonce => ?TEST_NONCE}, Missing)),
    Relative = cli_opts("bin/nvattest", #{}),
    ?assertEqual({error, nvattest_not_found},
        generate(#{}, #{nonce => ?TEST_NONCE}, Relative)),
    Body = hb_json:encode([test_evidence(?TEST_NONCE)]),
    ?assertEqual({error, nvattest_not_found},
        verify(#{}, #{<<"body">> => Body}, Missing)).

nvattest_generate_test() ->
    with_test_dir(fun(Dir) ->
        Opts = cli_opts(fake_nvattest(Dir, 0), #{}),
        Result = decoded(generate(#{}, #{nonce => ?TEST_NONCE}, Opts)),
        ?assertMatch(
            #{
                <<"nonce">> := ?TEST_NONCE,
                <<"verified">> := true,
                <<"evidences">> := [#{ <<"nonce">> := ?TEST_NONCE }],
                <<"claims">> := [#{ <<"eat_nonce">> := ?TEST_NONCE }],
                <<"eat">> := [[<<"JWT">>, _] | _]
            },
            Result
        ),
        ?assertEqual(
            [<<"claims">>, <<"eat">>, <<"evidences">>, <<"nonce">>, <<"verified">>],
            lists:sort(maps:keys(Result))
        )
    end).

nvattest_failure_is_not_verified_test() ->
    with_test_dir(fun(Dir) ->
        Opts = cli_opts(fake_nvattest(Dir, 1), #{}),
        ?assertMatch(#{ <<"verified">> := false },
            decoded(generate(#{}, #{nonce => ?TEST_NONCE}, Opts)))
    end).

nvattest_invalid_output_test() ->
    with_test_dir(fun(Dir) ->
        Script = write_script(Dir, "nvattest", "echo 'not json'\n"),
        ?assertEqual({error, nvattest_invalid_response},
            generate(#{}, #{nonce => ?TEST_NONCE}, cli_opts(Script, #{})))
    end).

nvattest_timeout_test() ->
    with_test_dir(fun(Dir) ->
        Script = write_script(Dir, "nvattest", "exec sleep 5\n"),
        Opts = cli_opts(Script, #{ <<"sev-gpu-nvattest-timeout">> => 200 }),
        {Micros, Result} =
            timer:tc(fun() -> generate(#{}, #{nonce => ?TEST_NONCE}, Opts) end),
        ?assertEqual({error, nvattest_timeout}, Result),
        ?assert(Micros < 3000000)
    end).

nvattest_verify_test() ->
    with_test_dir(fun(Dir) ->
        Opts = cli_opts(fake_nvattest(Dir, 0), #{ <<"sev-gpu-scratch-dir">> => hb_util:bin(Dir) }),
        Generated = decoded(generate(#{}, #{nonce => ?TEST_NONCE}, Opts)),
        %% Both the evidence array and the whole `generate' result are accepted.
        Evidences = hb_json:encode(maps:get(<<"evidences">>, Generated)),
        ?assertEqual({ok, <<"true">>}, verify(#{}, #{<<"body">> => Evidences}, Opts)),
        ?assertEqual({ok, <<"true">>},
            verify(#{}, #{<<"body">> => hb_json:encode(Generated)}, Opts)),
        ?assertEqual({ok, <<"true">>},
            verify(#{}, #{<<"body">> => Evidences, <<"nonce">> => ?TEST_NONCE}, Opts)),
        %% A JSON request body arrives as request keys rather than `body'.
        ?assertEqual({ok, <<"true">>},
            verify(#{}, #{<<"evidences">> => maps:get(<<"evidences">>, Generated)}, Opts)),
        %% The scratch file is removed after the run.
        {ok, Logged} = file:read_file(filename:join(Dir, "evidence-file")),
        ?assertNot(filelib:is_regular(string:trim(binary_to_list(Logged))))
    end).

verify_rejects_foreign_nonce_test() ->
    with_test_dir(fun(Dir) ->
        Opts = cli_opts(fake_nvattest(Dir, 0), #{ <<"sev-gpu-scratch-dir">> => hb_util:bin(Dir) }),
        Body = hb_json:encode([test_evidence(?TEST_NONCE)]),
        Other = binary:copy(<<"ef">>, 32),
        ?assertEqual({ok, <<"false">>},
            verify(#{}, #{<<"body">> => Body, <<"nonce">> => Other}, Opts)),
        ?assertEqual({error, invalid_nonce},
            verify(#{}, #{<<"body">> => Body, <<"nonce">> => <<"xyz">>}, Opts))
    end).

verify_input_is_validated_test() ->
    ?assertEqual({error, evidence_required}, verify(#{}, #{}, #{})),
    ?assertEqual({error, invalid_evidence},
        verify(#{}, #{<<"body">> => <<"not json">>}, #{})),
    ?assertEqual({error, invalid_evidence},
        verify(#{}, #{<<"body">> => <<"[]">>}, #{})),
    ?assertEqual({error, invalid_evidence},
        verify(#{}, #{<<"body">> => <<"[{\"nonce\":\"00\"}]">>}, #{})),
    Mixed = hb_json:encode([
        test_evidence(?TEST_NONCE),
        test_evidence(binary:copy(<<"ab">>, 32))
    ]),
    ?assertEqual({error, invalid_evidence}, verify(#{}, #{<<"body">> => Mixed}, #{})).

evidence_must_be_text_test() ->
    Good = test_evidence(?TEST_NONCE),
    ?assertEqual({error, invalid_evidence},
        verify(#{}, #{<<"evidences">> => [Good#{ <<"evidence">> => <<255, 254>> }]}, #{})),
    ?assertEqual({error, invalid_evidence},
        verify(#{}, #{<<"evidences">> => [Good#{ <<"arch">> => hopper }]}, #{})),
    ?assertEqual({error, invalid_evidence},
        verify(#{}, #{<<"evidences">> => [Good#{ <<"extra">> => {not_json} }]}, #{})),
    ?assertEqual({error, invalid_evidence},
        verify(#{}, #{<<"body">> => <<"[{\"arch\":1}]">>}, #{})).

wrapper_origin_is_compared_test() ->
    ?assert(same_beam("/opt/hb/dev_sev_gpu/dev_sev_gpu_nif.beam",
        "/opt/hb/dev_sev_gpu/dev_sev_gpu_nif")),
    ?assertNot(same_beam("/opt/hb/old/dev_sev_gpu_nif.beam",
        "/opt/hb/dev_sev_gpu/dev_sev_gpu_nif")),
    ?assertNot(same_beam(preloaded, "/opt/hb/dev_sev_gpu/dev_sev_gpu_nif")).

nif_backend_reports_unavailable_test() ->
    Result = generate(#{}, #{nonce => ?TEST_NONCE},
        #{ <<"sev-gpu-backend">> => <<"nif">> }),
    case nif() of
        ok -> ?assertNotEqual({error, nif_unavailable}, Result);
        {error, _} -> ?assertEqual({error, nif_unavailable}, Result)
    end.

%% Hardware tests. On a host with NVIDIA confidential computing they attest
%% the real GPU end to end; elsewhere `generate' must report the missing
%% backend as an error rather than return a result.
generate_test() ->
    Nonce = hb_util:to_hex(crypto:strong_rand_bytes(32)),
    case generate(#{}, #{nonce => Nonce}, #{}) of
        {ok, JSON} ->
            ?assertMatch(#{ <<"nonce">> := Nonce, <<"verified">> := true },
                hb_json:decode(JSON));
        {error, Reason} ->
            ?assert(attestation_unavailable(Reason))
    end.

verify_test() ->
    Nonce = hb_util:to_hex(crypto:strong_rand_bytes(32)),
    case generate(#{}, #{nonce => Nonce}, #{}) of
        {ok, JSON} ->
            ?assertEqual({ok, <<"true">>},
                verify(#{}, #{<<"body">> => JSON, <<"nonce">> => Nonce}, #{}));
        {error, Reason} ->
            ?assert(attestation_unavailable(Reason))
    end.

attestation_unavailable(nif_unavailable) -> true;
attestation_unavailable(nvattest_not_found) -> true;
attestation_unavailable(nvattest_timeout) -> true;
attestation_unavailable(nvattest_invalid_response) -> true;
attestation_unavailable({nvattest_spawn_failed, _}) -> true;
attestation_unavailable({nvat_error, _}) -> true;
attestation_unavailable(_) -> false.

-endif.
