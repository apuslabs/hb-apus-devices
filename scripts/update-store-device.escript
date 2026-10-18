#!/usr/bin/env escript
%% Repackage one device into an existing preloaded store and keep every other
%% device of the store exactly as it is.
%%
%% Usage (from the repository root, after `rebar3 compile'):
%%   escript scripts/update-store-device.escript STORE WALLET DEVICE_ROOT
%%
%% DEVICE_ROOT is the Device Forge root module of the device, for example
%% dev_inference_receipt. The device is packaged from src and
%% vendor/permaweb-os/src, its specification and implementation messages are
%% signed with WALLET and written to STORE, and the store's device index is
%% re-signed with the device name pointing at the new specification.
%%
%% This replaces a single device without rebuilding the others, so archives
%% that carry native libraries built on the target host are retained. Run it
%% on a copy of the store, with no node using that copy.
-mode(compile).

-define(INDEX_KEY, <<"~meta@1.0/preloaded-devices-index">>).
-define(DEVICE_SOURCES, [<<"src">>, <<"vendor/permaweb-os/src">>]).

main([StoreDir, KeyPath, Root]) ->
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
            try
                {ok, Index0} = hb_cache:read(?INDEX_KEY, Opts),
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
        "Usage: escript scripts/update-store-device.escript STORE WALLET DEVICE_ROOT~n",
        []),
    halt(1).

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

fail(Format, Args) ->
    io:format(standard_error, "error: " ++ Format ++ "~n", Args),
    halt(1).
