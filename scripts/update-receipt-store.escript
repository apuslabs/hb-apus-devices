#!/usr/bin/env escript
%% Update an OFFLINE COPY of a Forge store without replacing native devices.
-mode(compile).

main([StoreDir, KeyPath]) ->
    code:add_paths(filelib:wildcard("_build/default/lib/*/ebin")),
    application:ensure_all_started(crypto),
    application:ensure_all_started(prometheus),
    hb_forge_seed:with_forge_bootstrap(
        #{<<"bootstrap-device-src">> => [<<"_build/default/lib/hb/src/preloaded">>]},
        fun(SeedOpts) ->
            Store = #{<<"store-module">> => hb_store_lmdb,
                <<"name">> => list_to_binary(StoreDir),
                <<"capacity">> => 1073741824, <<"lock">> => false},
            Opts = SeedOpts#{<<"store">> => [Store],
                <<"priv-wallet">> => hb:wallet(KeyPath), <<"on">> => #{}},
            ok = hb_store:start(Store, #{}, Opts),
            IndexKey = <<"~meta@1.0/preloaded-devices-index">>,
            {ok, Index0} = hb_cache:read(IndexKey, Opts),
            Index = maps:filter(fun(K, _V) ->
                binary:match(K, <<"@">>) =/= nomatch
            end, Index0),
            Groups = hb_packager:scan([<<"src">>],
                #{<<"device-roots">> => [dev_inference_receipt]}),
            [Pkg] = hb_packager:package_all(Groups, Opts),
            SpecID = persist(hb_packager:spec_message(Pkg, Opts), Opts),
            ImplID = persist(hb_packager:impl_message(Pkg, SpecID, Opts), Opts),
            IndexID = persist(Index#{<<"inference_receipt@1.0">> => SpecID}, Opts),
            ok = hb_store:link(Store, #{IndexKey => IndexID}, Opts),
            ok = hb_store:stop(Store, #{}, Opts),
            io:format("Store: ~s~nIndex: ~s~nReceipt implementation: ~s~n",
                [StoreDir, IndexID, ImplID])
        end
    );
main(_) ->
    io:format(standard_error,
        "Usage: escript scripts/update-receipt-store.escript OFFLINE_STORE WALLET~n", []),
    halt(1).

persist(Message, Opts) ->
    Signed = hb_message:commit(Message, Opts),
    {ok, _} = hb_cache:write(Signed, Opts),
    [ID | _] = lists:sort([K || {K, #{<<"committer">> := _}} <-
        maps:to_list(maps:get(<<"commitments">>, Signed))]),
    ID.
