%%% @doc Erlang side of the NVIDIA attestation SDK (NVAT) NIF.
%%%
%%% `sev_gpu@1.0' loads this module from its implementation directory with
%%% `code:load_abs/1' and then calls `load/1' with the path of the shared
%%% library next to it. The module always carries the name `dev_sev_gpu_nif',
%%% which is the name the library declares in `ERL_NIF_INIT', so the library
%%% loads whatever generated name Device Forge gives the device module.
%%%
%%% Every function below except `load/1' is replaced by the NIF when the
%%% library loads; until then each one reports that the library is absent.
-module(dev_sev_gpu_nif).
-export([load/1, loaded/0, collect_evidence/1, verify_evidence/1]).

%% @doc Load the NIF library at `Path' (without the `.so' extension).
-spec load(file:filename_all()) -> ok | {error, term()}.
load(Path) ->
    case erlang:load_nif(Path, 0) of
        ok -> ok;
        {error, {reload, _}} = Error ->
            %% Another process loaded the library first.
            case loaded() of
                true -> ok;
                false -> Error
            end;
        {error, _} = Error -> Error
    end.

%% @doc `true' once the NIF library is loaded.
-spec loaded() -> boolean().
loaded() ->
    false.

%% @doc Collect GPU evidence for a hex nonce and verify it with NVAT's local
%% verifier. Returns a JSON object with `verified', `evidences', `claims' and
%% `eat', or an NVAT error string.
-spec collect_evidence(binary()) -> {ok, binary()} | {error, binary()}.
collect_evidence(_Nonce) ->
    erlang:nif_error(not_loaded).

%% @doc Verify serialized GPU evidence with NVAT's local verifier. The input
%% is a JSON object with `nonce', `evidences' and `scratch-dir'. Returns a
%% JSON object with `verified', `claims' and `eat', or an NVAT error string.
-spec verify_evidence(binary()) -> {ok, binary()} | {error, binary()}.
verify_evidence(_Request) ->
    erlang:nif_error(not_loaded).
