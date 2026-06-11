%%% @doc NVIDIA GPU TEE Attestation Device
%%%
%%% This module provides GPU attestation capabilities using the NVIDIA nvat SDK.
%%% It uses Erlang NIFs to directly call the nvat C API for:
%%% - Collecting GPU attestation evidence
%%% - Verifying GPU attestation evidence locally
%%%
%%% The NIF handles SDK initialization internally, so no explicit setup is required.
-module(dev_sev_gpu).
-implements(<<"sev_gpu@1.0">>).
-export([info/1, generate/3, verify/3]).
-on_load(init/0).
-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(TEST_MOCK_NONCE, <<"da4a06c3604a5fac8aa0b4aaf5a6354cdd0dc7c193299bc3464f30b5cbfb931a">>).

%% NIF stubs - these are replaced by the actual NIF functions when loaded
-spec collect_evidence_nif(binary()) -> {ok, binary()} | {error, binary()}.
collect_evidence_nif(_Nonce) -> erlang:nif_error(not_loaded).

-spec verify_evidence_nif(binary()) -> {ok, binary()} | {error, binary()}.
verify_evidence_nif(_EvidenceJSON) -> erlang:nif_error(not_loaded).

%% NIF initialization
init() ->
    ImplDir =
        try hb_device_archive:implementation_dir(?MODULE) of
            Dir -> Dir
        catch
            _:_ ->
                %% Source-tree fallback for `rebar3 compile` before Forge packaging.
                filename:absname("priv/dev_sev_gpu")
        end,
    LibDir = filename:join(ImplDir, "lib"),
    ExistingLdPath = os:getenv("LD_LIBRARY_PATH"),
    case filelib:is_dir(LibDir) of
        true when ExistingLdPath =:= false ->
            os:putenv("LD_LIBRARY_PATH", LibDir);
        true ->
            os:putenv("LD_LIBRARY_PATH", LibDir ++ ":" ++ ExistingLdPath);
        false ->
            ok
    end,
    SoPath = filename:join(ImplDir, "dev_sev_gpu_nif"),
    case erlang:load_nif(SoPath, 0) of
        ok -> ok;
        {error, {reload, _}} -> ok;
        {error, Reason} -> 
            ?event({nif_load_error, Reason}),
            ok  %% Don't fail module load, but NIF calls will return not_loaded
    end.

info(_) -> 
    #{exports => [<<"info">>, <<"generate">>, <<"verify">>]}.

%% @doc Generate GPU attestation evidence.
%%
%% Collects attestation evidence from the GPU using NVML, verifies it locally,
%% and returns a JSON object containing:
%% - evidences: Serialized GPU evidence (for transport to verifier)
%% - claims: Attestation claims from local verification
%% - eat: Detached Entity Attestation Token
%% - verified: Boolean indicating local verification success
%%
%% Input message M2 should contain:
%% - nonce: Hex-encoded nonce for attestation freshness
-spec generate(map(), map(), map()) -> {ok, binary()} | {error, term()}.
generate(_M1, M2, Opts) ->
    Nonce = hb_ao:get(nonce, M2, ?TEST_MOCK_NONCE, Opts),
    case safe_collect_evidence(Nonce) of
        {ok, ResultJSON} ->
            {ok, ResultJSON};
        {error, Reason} when is_binary(Reason) ->
            {error, {nvat_error, Reason}};
        {error, not_loaded} ->
            {error, nif_not_loaded}
    end.

%% @doc Verify GPU attestation evidence.
%%
%% Verifies previously collected GPU evidence locally.
%% The evidence JSON already contains the nonce from when it was collected.
%%
%% Input message M2 should contain:
%% - body: The evidences JSON from a previous generate call
%%
%% Returns:
%% - {ok, <<"true">>} if verification succeeds
%% - {ok, <<"false">>} if verification fails
%% - {error, Reason} on error
-spec verify(map(), map(), map()) -> {ok, binary()} | {error, term()}.
verify(_M1, M2, _Opts) ->
    EvidenceJSON = maps:get(<<"body">>, M2, <<>>),
    case safe_verify_evidence(EvidenceJSON) of
        {ok, ResultJSON} ->
            case hb_json:decode(ResultJSON) of
                #{<<"valid">> := true} -> {ok, <<"true">>};
                #{<<"valid">> := false} -> {ok, <<"false">>};
                _ -> {ok, <<"false">>}
            end;
        {error, Reason} when is_binary(Reason) ->
            {error, {nvat_error, Reason}};
        {error, not_loaded} ->
            {error, nif_not_loaded}
    end.

safe_collect_evidence(Nonce) ->
    try collect_evidence_nif(Nonce)
    catch
        error:not_loaded -> {error, not_loaded};
        error:{nif_not_loaded, _} -> {error, not_loaded}
    end.

safe_verify_evidence(EvidenceJSON) ->
    try verify_evidence_nif(EvidenceJSON)
    catch
        error:not_loaded -> {error, not_loaded};
        error:{nif_not_loaded, _} -> {error, not_loaded}
    end.

%% ============================================================================
%% Unit Tests
%% ============================================================================

generate_test() ->
    case generate(#{}, #{nonce => ?TEST_MOCK_NONCE}, #{}) of
        {ok, ResultJSON} ->
            ?assert(is_binary(ResultJSON)),
            ?assert(byte_size(ResultJSON) > 0),
            case hb_json:decode(ResultJSON) of
                #{<<"evidences">> := _, <<"verified">> := true} ->
                    ?assert(true);
                _ ->
                    ?assert(false)
            end;
        {error, nif_not_loaded} ->
            {skip, "dev_sev_gpu NIF is not available"};
        {error, {nvat_error, _}} ->
            {skip, "NVIDIA attestation is not available on this machine"};
        {error, _Reason} ->
            {skip, "GPU attestation is not available"}
    end.

verify_test() ->
    case generate(#{}, #{nonce => ?TEST_MOCK_NONCE}, #{}) of
        {ok, ResultJSON} ->
            case hb_json:decode(ResultJSON) of
                #{<<"evidences">> := Evidences} ->
                    VerifyMsg = #{<<"body">> => hb_json:encode(Evidences)},
                    case verify(#{}, VerifyMsg, #{}) of
                        {ok, <<"true">>} ->
                            ?assert(true);
                        {ok, <<"false">>} ->
                            ?assert(false);
                        {error, _} ->
                            ?assert(false)
                    end;
                _ ->
                    ?assert(false)
            end;
        {error, nif_not_loaded} ->
            {skip, "dev_sev_gpu NIF is not available"};
        {error, {nvat_error, _}} ->
            {skip, "NVIDIA attestation is not available on this machine"};
        {error, _Reason} ->
            {skip, "GPU attestation is not available"}
    end.
