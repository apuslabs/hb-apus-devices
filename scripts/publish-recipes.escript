#!/usr/bin/env escript
%% Sign docs/recipes/*/*.md as Device-Recipe messages and upload them.
%%
%% Usage (from the repository root, after `rebar3 compile`):
%%   escript scripts/publish-recipes.escript PRELOADED_STORE WALLET [--upload]
%%       [--expect ADDRESS] [--bundler URL]
%%
%% Each recipe's `recipe-for-device' is the device's specification ID in
%% PRELOADED_STORE, so the store must be the one the node will run. Without
%% `--upload' the recipes are signed and their IDs printed, nothing is sent.
-mode(compile).

-define(INDEX_KEY, <<"~meta@1.0/preloaded-devices-index">>).
-define(DEFAULT_BUNDLER, <<"https://up.arweave.net:443">>).

main([StoreDir, KeyPath | Flags]) ->
    code:add_paths(filelib:wildcard("_build/default/lib/*/ebin")),
    {ok, _} = application:ensure_all_started(crypto),
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(inets),
    Upload = lists:member("--upload", Flags),
    Bundler = list_to_binary(flag("--bundler", Flags, binary_to_list(?DEFAULT_BUNDLER))),
    Wallet = load_wallet(KeyPath),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    AddressStr = binary_to_list(Address),
    case flag("--expect", Flags, undefined) of
        undefined -> ok;
        AddressStr -> ok;
        Expected -> fail("wallet ~s is ~s, expected ~s", [KeyPath, Address, Expected])
    end,
    Bootstrap = #{
        <<"bootstrap-device-src">> => [<<"_build/default/lib/hb/src/preloaded">>],
        <<"commitment-device">> => <<"ans104@1.0">>
    },
    %% Codec devices are packaged in this HyperBEAM version. Outside a node,
    %% the Forge seed compiles them from source so messages can be signed.
    hb_forge_seed:with_forge_bootstrap(
        Bootstrap,
        fun(SeedOpts) ->
            Opts = SeedOpts#{
                <<"priv-wallet">> => Wallet,
                <<"bundler-ans104">> => Bundler,
                <<"prometheus">> => false
            },
            Specs = spec_ids(StoreDir, SeedOpts),
            Recipes = lists:sort(filelib:wildcard("docs/recipes/*/*.md")),
            io:format("Signer: ~s~nStore: ~s~nBundler: ~s~nMode: ~s~n~n",
                [Address, StoreDir, Bundler,
                    if Upload -> "upload"; true -> "dry-run" end]),
            Results = [publish(Path, Specs, Upload, Opts) || Path <- Recipes],
            write_ledger(Results, Address, Upload),
            io:format("~n~p recipes ~s.~n",
                [length(Results),
                    if Upload -> "uploaded"; true -> "signed (dry run)" end])
        end
    );
main(_) ->
    io:format(standard_error,
        "Usage: escript scripts/publish-recipes.escript PRELOADED_STORE WALLET "
        "[--upload] [--expect ADDRESS] [--bundler URL]~n", []),
    halt(1).

publish(Path, Specs, Upload, Opts) ->
    Device = <<(list_to_binary(filename:basename(filename:dirname(Path))))/binary, "@1.0">>,
    SpecID =
        case maps:find(Device, Specs) of
            {ok, Found} -> Found;
            error -> fail("~s: ~s is not in the preloaded store", [Path, Device])
        end,
    {Meta, Body} = parse(Path),
    Slug = maps:get(<<"slug">>, Meta, list_to_binary(filename:basename(Path, ".md"))),
    Title = maps:get(<<"title">>, Meta, Slug),
    Message = #{
        <<"data-protocol">> => <<"ao">>,
        <<"variant">> => <<"ao.N.1">>,
        <<"type">> => <<"Device-Recipe">>,
        <<"content-type">> => <<"text/markdown">>,
        <<"recipe-for-device">> => SpecID,
        <<"primary-device">> => Device,
        <<"recipe-kind">> => <<"local-example">>,
        <<"slug">> => Slug,
        <<"title">> => Title,
        <<"source-path">> => list_to_binary(Path),
        <<"body">> => Body
    },
    Signed = hb_message:commit(Message, Opts, <<"ans104@1.0">>),
    ID = hb_message:id(Signed, all, Opts),
    case Upload of
        false -> ok;
        true ->
            case upload(Signed, Opts) of
                {ok, _} -> ok;
                Error -> fail("~s: upload failed: ~0p", [Path, Error])
            end
    end,
    io:format("~s ~s ~s~n", [ID, Device, Slug]),
    #{ id => ID, device => Device, slug => Slug, spec => SpecID }.

%% @doc Serialize the committed message as an ANS-104 item and post it to the
%% bundler, as `rebar3 device publish' does.
upload(Msg, Opts) ->
    {ok, Committed} = hb_message:with_only_committed(hb_private:reset(Msg), Opts),
    Item =
        ar_bundles:serialize(
            hb_message:convert(
                Committed,
                #{ <<"device">> => <<"ans104@1.0">>, <<"bundle">> => true },
                Opts
            )
        ),
    URL = binary_to_list(maps:get(<<"bundler-ans104">>, Opts)) ++ "/~bundler@1.0/tx",
    Headers = [{"codec-device", "ans104@1.0"}, {"accept-bundle", "true"}],
    HTTPOpts = [
        {timeout, 60000},
        {ssl, [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {customize_hostname_check,
                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
        ]}
    ],
    case httpc:request(post, {URL, Headers, "application/ans104", Item}, HTTPOpts,
            [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, Body}} when Status < 400 -> {ok, Body};
        {ok, {{_, Status, _}, _, Body}} -> {error, {Status, Body}};
        Error -> Error
    end.

%% @doc Device name -> specification ID from a copy of the preloaded store.
spec_ids(StoreDir, SeedOpts) ->
    Tmp = filename:join("/tmp", "publish-recipes-" ++ os:getpid()),
    ok = filelib:ensure_dir(filename:join(Tmp, "x")),
    {ok, _} = file:copy(filename:join(StoreDir, "data.mdb"), filename:join(Tmp, "data.mdb")),
    Store = #{
        <<"store-module">> => hb_store_lmdb,
        <<"name">> => list_to_binary(Tmp),
        <<"capacity">> => 1073741824
    },
    Opts = SeedOpts#{ <<"store">> => [Store] },
    ok = hb_store:start(Store, #{}, Opts),
    {ok, Index} = hb_cache:read(?INDEX_KEY, Opts),
    Specs =
        maps:from_list(
            [
                {Name, hb_util:bin(hb_cache:ensure_loaded(Ref, Opts))}
            ||
                {Name, Ref} <- maps:to_list(Index),
                is_binary(Name),
                binary:match(Name, <<"@">>) =/= nomatch
            ]
        ),
    hb_store:stop(Store, #{}, Opts),
    os:cmd("rm -rf " ++ Tmp),
    Specs.

%% @doc Split `---' front matter (`key: value' lines) from the markdown body.
parse(Path) ->
    {ok, Bin} = file:read_file(Path),
    case binary:split(Bin, <<"---\n">>, [global]) of
        [<<>>, Front, Body | Rest] ->
            Meta =
                maps:from_list(
                    [
                        {string:trim(K), string:trim(V)}
                    ||
                        Line <- binary:split(Front, <<"\n">>, [global]),
                        [K, V] <- [binary:split(Line, <<":">>)]
                    ]
                ),
            {Meta, iolist_to_binary(lists:join(<<"---\n">>, [Body | Rest]))};
        _ ->
            {#{}, Bin}
    end.

load_wallet(KeyPath) ->
    case filelib:is_regular(KeyPath) of
        true -> ar_wallet:load_keyfile(KeyPath);
        false -> fail("wallet file not found: ~s", [KeyPath])
    end.

write_ledger(Results, Address, true) ->
    Lines = [
        "# Published Device Recipes\n\n",
        "- Signer: ", Address, "\n",
        "- Published at: ", calendar:system_time_to_rfc3339(erlang:system_time(second),
            [{offset, "Z"}]), "\n\n",
        "| Recipe ID | Device | Slug | Spec ID |\n|---|---|---|---|\n",
        [["| ", ID, " | ", D, " | ", S, " | ", Spec, " |\n"]
            || #{ id := ID, device := D, slug := S, spec := Spec } <- Results]
    ],
    ok = file:write_file("docs/recipes/PUBLISHED.md", Lines);
write_ledger(_Results, _Address, false) ->
    ok.

flag(Name, [Name, Value | _], _Default) -> Value;
flag(Name, [_ | Rest], Default) -> flag(Name, Rest, Default);
flag(_Name, [], Default) -> Default.

fail(Format, Args) ->
    io:format(standard_error, "error: " ++ Format ++ "~n", Args),
    halt(1).
