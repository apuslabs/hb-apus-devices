#!/usr/bin/env escript
%% Repackage one device into an existing preloaded store and keep every other
%% device of the store exactly as it is.
%%
%% Usage (from the repository root, after `rebar3 compile'):
%%   escript scripts/update-store-device.escript STORE WALLET DEVICE_ROOT
%%       [--expect ADDRESS]
%%
%% DEVICE_ROOT is the Device Forge root module of the device, for example
%% dev_inference_receipt. The device is packaged from src and
%% vendor/permaweb-os/src, its specification and implementation messages are
%% signed with WALLET and written to STORE, and the store's device index is
%% re-signed with the device name pointing at the new specification.
%%
%% WALLET must be a signer of the store's current device index, so that the
%% messages the update adds have the same signer as the rest of the store.
%% --expect ADDRESS accepts a WALLET with that address instead, for example
%% to move a store to a new signing key.
%%
%% This replaces a single device without rebuilding the others, so archives
%% that carry native libraries built on the target host are retained. Run it
%% on a copy of the store, with no node using that copy.
-mode(compile).

-define(INDEX_KEY, <<"~meta@1.0/preloaded-devices-index">>).
-define(DEVICE_SOURCES, [<<"src">>, <<"vendor/permaweb-os/src">>]).

main([StoreDir, KeyPath, Root | Flags]) ->
    filelib:is_dir("src")
        orelse fail("run this script from the repository root", []),
    filelib:is_regular(filename:join(StoreDir, "data.mdb"))
        orelse fail("~s is not a preloaded store (no data.mdb)", [StoreDir]),
    filelib:is_regular(KeyPath)
        orelse fail("wallet keyfile not found: ~s", [KeyPath]),
    code:add_paths(filelib:wildcard("_build/default/lib/*/ebin")),
    lists:foreach(
        fun(App) -> {ok, _} = application:ensure_all_started(App) end,
        [crypto, prometheus]
    ),
    Wallet = ar_wallet:load_keyfile(KeyPath),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    Expected = flag("--expect", Flags, undefined),
    Expected =:= undefined orelse Expected =:= binary_to_list(Address)
        orelse fail("wallet ~s has address ~s, expected ~s",
            [KeyPath, Address, Expected]),
    hb_forge_seed:with_forge_bootstrap(
        #{ <<"bootstrap-device-src">> => [<<"_build/default/lib/hb/src/preloaded">>] },
        fun(SeedOpts) ->
            Groups =
                hb_packager:scan(
                    ?DEVICE_SOURCES,
                    #{ <<"device-roots">> => [list_to_binary(Root)] }
                ),
            Groups =/= []
                orelse fail("~s is not a device root in src or vendor/permaweb-os/src",
                    [Root]),
            Store = #{
                <<"store-module">> => hb_store_lmdb,
                <<"name">> => list_to_binary(StoreDir),
                <<"capacity">> => 1073741824,
                <<"lock">> => false
            },
            Opts = SeedOpts#{
                <<"store">> => [Store],
                <<"priv-wallet">> => Wallet,
                <<"on">> => #{}
            },
            ok = hb_store:start(Store, #{}, Opts),
            Index0 =
                case hb_cache:read(?INDEX_KEY, Opts) of
                    {ok, Found} -> Found;
                    _ ->
                        catch hb_store:stop(Store, #{}, Opts),
                        fail("~s is not a preloaded store (no device index); "
                            "run make preload", [StoreDir])
                end,
            Signers = index_signers(Store, Opts),
            lists:member(Address, Signers) orelse Expected =/= undefined
                orelse begin
                    catch hb_store:stop(Store, #{}, Opts),
                    fail("the device index of ~s is signed by ~s, not by ~s; "
                        "pass --expect ~s to re-sign it with this wallet",
                        [StoreDir, signer_list(Signers), Address, Address])
                end,
            try
                Index =
                    maps:filter(
                        fun(Name, _SpecID) ->
                            is_binary(Name)
                                andalso binary:match(Name, <<"@">>) =/= nomatch
                        end,
                        Index0
                    ),
                [Pkg] = hb_packager:package_all(Groups, Opts),
                Name = maps:get(device_name, Pkg),
                SpecID = persist(hb_packager:spec_message(Pkg, Opts), Opts),
                ImplID = persist(hb_packager:impl_message(Pkg, SpecID, Opts), Opts),
                IndexID = persist(Index#{ Name => SpecID }, Opts),
                ok = hb_store:link(Store, #{ ?INDEX_KEY => IndexID }, Opts),
                io:format(
                    "Store: ~s~nDevice: ~s~nSpecification ID: ~s~n"
                    "Implementation ID: ~s~nIndex: ~s~n",
                    [StoreDir, Name, SpecID, ImplID, IndexID]
                )
            after
                hb_store:stop(Store, #{}, Opts)
            end
        end
    );
main(_) ->
    io:format(standard_error,
        "Usage: escript scripts/update-store-device.escript STORE WALLET DEVICE_ROOT "
        "[--expect ADDRESS]~n",
        []),
    halt(1).

%% @doc Addresses of the signers of the store's current device index. The
%% index key links to the signed index message, which carries the
%% commitments.
index_signers(Store, Opts) ->
    IndexID =
        case hb_store:resolve([Store], ?INDEX_KEY, Opts) of
            {ok, Resolved} -> Resolved;
            Resolved -> Resolved
        end,
    case is_binary(IndexID) andalso hb_cache:read(IndexID, Opts) of
        {ok, Signed} when is_map(Signed) ->
            Commitments =
                hb_cache:ensure_all_loaded(
                    maps:get(<<"commitments">>, Signed, #{}),
                    Opts
                ),
            lists:usort(
                [
                    hb_util:human_id(Committer)
                ||
                    #{ <<"committer">> := Committer } <- maps:values(Commitments),
                    is_binary(Committer)
                ]
            );
        _ ->
            []
    end.

signer_list([]) -> "an unknown signer";
signer_list(Signers) -> lists:join(", ", Signers).

%% @doc Sign a message, write it to the store and return its signed ID.
persist(Message, Opts) ->
    Signed = hb_message:commit(Message, Opts),
    {ok, _} = hb_cache:write(Signed, Opts),
    [ID | _] =
        lists:sort(
            [
                CommitmentID
            ||
                {CommitmentID, #{ <<"committer">> := _ }} <-
                    maps:to_list(maps:get(<<"commitments">>, Signed))
            ]
        ),
    ID.

flag(Name, [Name, Value | _], _Default) -> Value;
flag(Name, [_ | Rest], Default) -> flag(Name, Rest, Default);
flag(_Name, [], Default) -> Default.

fail(Format, Args) ->
    io:format(standard_error, "error: " ++ Format ++ "~n", Args),
    halt(1).
