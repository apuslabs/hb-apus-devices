#!/usr/bin/env escript
%% Sign the recipes in docs/recipes/<device>/<slug>.md as Device-Recipe
%% messages and, with --upload, submit them to an ANS-104 bundler.
%%
%% Usage (from the repository root, after `rebar3 compile'):
%%   escript scripts/publish-recipes.escript SPECS WALLET [--upload]
%%       [--expect ADDRESS] [--bundler URL] [--only PATH-SUBSTRING]
%%       [--ledger PATH]
%%
%% Each recipe's `recipe-for-device' tag is the specification ID of its
%% device, read from SPECS, which is either:
%%   - a publication record written by `make publish' (PUBLISH.md): the IDs
%%     of the Device-Specification messages published on Arweave. WALLET
%%     must have the signer address of the record, so that recipes and
%%     specifications share one signer; or
%%   - a preloaded store directory (`make preload'): the specification IDs
%%     of the devices that a node running this store loads. These IDs exist
%%     only in that store.
%%
%% Without --upload the recipes are signed and their IDs printed; nothing is
%% sent. With --upload each signed recipe is posted to the bundler (default
%% https://up.arweave.net:443) and appended to the ledger (default
%% docs/recipes/PUBLISHED.md) as soon as the bundler accepts it. --expect
%% aborts unless WALLET has the given address. --only selects the recipes
%% whose path contains the substring.
-mode(compile).

-define(INDEX_KEY, <<"~meta@1.0/preloaded-devices-index">>).
-define(DEFAULT_BUNDLER, "https://up.arweave.net:443").
-define(DEFAULT_LEDGER, "docs/recipes/PUBLISHED.md").
-define(RECIPES, "docs/recipes/*/*.md").
-define(ID_PATTERN, "[A-Za-z0-9_-]{43}").

main([SpecSource, KeyPath | Flags]) ->
    filelib:is_dir("docs/recipes")
        orelse fail("run this script from the repository root", []),
    code:add_paths(filelib:wildcard("_build/default/lib/*/ebin")),
    lists:foreach(
        fun(App) -> {ok, _} = application:ensure_all_started(App) end,
        [crypto, ssl, hackney]
    ),
    Upload = lists:member("--upload", Flags),
    Bundler = list_to_binary(flag("--bundler", Flags, ?DEFAULT_BUNDLER)),
    Ledger = flag("--ledger", Flags, ?DEFAULT_LEDGER),
    Only = flag("--only", Flags, ""),
    Wallet = load_wallet(KeyPath),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    case flag("--expect", Flags, undefined) of
        undefined -> ok;
        Expected ->
            Expected =:= binary_to_list(Address)
                orelse fail("wallet ~s has address ~s, expected ~s",
                    [KeyPath, Address, Expected])
    end,
    Bootstrap = #{
        <<"bootstrap-device-src">> => [<<"_build/default/lib/hb/src/preloaded">>],
        <<"commitment-device">> => <<"ans104@1.0">>
    },
    % Codec devices are packaged in this HyperBEAM version. Outside a node,
    % the Forge seed compiles them from source so messages can be signed.
    hb_forge_seed:with_forge_bootstrap(
        Bootstrap,
        fun(SeedOpts) ->
            Opts = SeedOpts#{
                <<"priv-wallet">> => Wallet,
                <<"bundler-ans104">> => Bundler,
                <<"prometheus">> => false
            },
            case Upload of
                true -> start_http_client(Opts);
                false -> ok
            end,
            Specs = spec_ids(SpecSource, Address, SeedOpts),
            Recipes =
                [
                    Path
                ||
                    Path <- lists:sort(filelib:wildcard(?RECIPES)),
                    string:find(Path, Only) =/= nomatch
                ],
            io:format("Signer: ~s~nSpecifications: ~s~nBundler: ~s~nMode: ~s~n~n",
                [Address, SpecSource, Bundler, mode(Upload)]),
            % Each uploaded recipe is recorded before the next one is sent,
            % so the ledger lists every upload even if a later one fails.
            {_Round, Count} =
                lists:foldl(
                    fun(Path, {Round, N}) ->
                        Result = publish(Path, Specs, Upload, Opts),
                        NextRound =
                            case Upload of
                                true -> record(Ledger, Round, Address, Result);
                                false -> Round
                            end,
                        {NextRound, N + 1}
                    end,
                    {not_started, 0},
                    Recipes
                ),
            io:format("~n~p recipes ~s.~n", [Count, outcome(Upload)]),
            case Upload andalso Count > 0 of
                true -> io:format("Ledger: ~s~n", [Ledger]);
                false -> ok
            end
        end
    );
main(_) ->
    io:format(standard_error,
        "Usage: escript scripts/publish-recipes.escript SPECS WALLET [--upload] "
        "[--expect ADDRESS] [--bundler URL] [--only PATH] [--ledger PATH]~n", []),
    halt(1).

mode(true) -> "upload";
mode(false) -> "dry run".

outcome(true) -> "uploaded";
outcome(false) -> "signed (dry run)".

%% @doc Sign one recipe file and, when uploading, post it to the bundler.
publish(Path, Specs, Upload, Opts) ->
    Device =
        <<(list_to_binary(filename:basename(filename:dirname(Path))))/binary,
            "@1.0">>,
    SpecID =
        case maps:find(Device, Specs) of
            {ok, Found} -> Found;
            error -> fail("~s: no specification ID for ~s", [Path, Device])
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
        <<"published-at">> => integer_to_binary(erlang:system_time(second)),
        <<"body">> => Body
    },
    Signed = hb_message:commit(Message, Opts, <<"ans104@1.0">>),
    ID = hb_message:id(Signed, all, Opts),
    case Upload of
        false -> ok;
        true ->
            case upload(Signed, Opts) of
                {ok, _} -> ok;
                Error ->
                    fail("~s: upload failed: ~0p; the recipes uploaded "
                        "before it in this run are in the ledger", [Path, Error])
            end
    end,
    io:format("~s ~s ~s~n", [ID, Device, Slug]),
    #{ id => ID, device => Device, slug => Slug, spec => SpecID }.

%% @doc Start HyperBEAM's HTTP client, which carries the bundler uploads.
start_http_client(Opts) ->
    case hb_http_client:start_link(Opts) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

%% @doc Serialize the committed message as an ANS-104 data item and post it
%% to the bundler through HyperBEAM's HTTP client.
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
    Req = #{
        peer => maps:get(<<"bundler-ans104">>, Opts),
        path => <<"/~bundler@1.0/tx">>,
        method => <<"POST">>,
        headers => #{
            <<"codec-device">> => <<"ans104@1.0">>,
            <<"content-type">> => <<"application/ans104">>,
            <<"accept-bundle">> => <<"true">>
        },
        body => Item
    },
    case hb_http_client:request(Req, Opts) of
        {ok, Status, _Headers, Body} when Status < 400 -> {ok, Body};
        {ok, Status, _Headers, Body} -> {error, {Status, Body}};
        Error -> Error
    end.

%% @doc Device name to specification ID, from a preloaded store directory or
%% from a publication record.
spec_ids(Source, Address, SeedOpts) ->
    case {filelib:is_dir(Source), filelib:is_regular(Source)} of
        {true, _} -> store_spec_ids(Source, SeedOpts);
        {false, true} -> record_spec_ids(Source, Address);
        _ -> fail("specification source not found: ~s", [Source])
    end.

%% @doc Read the device index of a preloaded store. The store is copied first
%% so that the original is never opened for writing.
store_spec_ids(StoreDir, SeedOpts) ->
    Data = filename:join(StoreDir, "data.mdb"),
    filelib:is_regular(Data)
        orelse fail("~s is not a preloaded store (no data.mdb)", [StoreDir]),
    Tmp = filename:join("_build", "recipe-specs-" ++ os:getpid()),
    ok = filelib:ensure_dir(filename:join(Tmp, "data.mdb")),
    {ok, _} = file:copy(Data, filename:join(Tmp, "data.mdb")),
    Store = #{
        <<"store-module">> => hb_store_lmdb,
        <<"name">> => list_to_binary(Tmp),
        <<"capacity">> => 1073741824
    },
    Opts = SeedOpts#{ <<"store">> => [Store] },
    Result =
        try
            ok = hb_store:start(Store, #{}, Opts),
            case hb_cache:read(?INDEX_KEY, Opts) of
                {ok, Index} ->
                    {ok,
                        maps:from_list(
                            [
                                {Name,
                                    hb_util:bin(hb_cache:ensure_loaded(Ref, Opts))}
                            ||
                                {Name, Ref} <- maps:to_list(Index),
                                is_binary(Name),
                                binary:match(Name, <<"@">>) =/= nomatch
                            ]
                        )};
                _ ->
                    no_index
            end
        after
            catch hb_store:stop(Store, #{}, Opts),
            file:del_dir_r(Tmp)
        end,
    case Result of
        {ok, Specs} -> Specs;
        no_index ->
            fail("~s is not a preloaded store (no device index); run make preload",
                [StoreDir])
    end.

%% @doc Read the device table of a publication record written by
%% `make publish': | `name@1.0` | `SpecID` | `ImplID` |. The record's signer
%% must be the address of the recipe wallet.
record_spec_ids(Path, Address) ->
    {ok, Bin} = file:read_file(Path),
    Pattern =
        "^\\| `([^`]+@[^`]+)` \\| `(" ?ID_PATTERN ")` \\| `" ?ID_PATTERN "` \\|",
    Specs =
        case re:run(Bin, Pattern, [multiline, global, {capture, all_but_first, binary}]) of
            {match, Rows} -> maps:from_list([{Name, Spec} || [Name, Spec] <- Rows]);
            nomatch -> fail("~s lists no published device; run make publish first", [Path])
        end,
    SignerPattern = "^\\| Signer \\| `(" ?ID_PATTERN ")` \\|",
    case re:run(Bin, SignerPattern, [multiline, {capture, all_but_first, binary}]) of
        {match, [Address]} -> Specs;
        {match, [Signer]} ->
            fail("~s was signed by ~s; sign the recipes with that wallet, not ~s",
                [Path, Signer, Address]);
        nomatch -> fail("~s records no signer", [Path])
    end.

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
        false -> fail("wallet keyfile not found: ~s", [KeyPath])
    end.

%% @doc Append one uploaded recipe to the ledger. The first upload of a run
%% opens a new round section. Block heights are filled in from Arweave
%% GraphQL once the bundles are confirmed.
record(Ledger, not_started, Address, Result) ->
    Header =
        case filelib:is_regular(Ledger) of
            true -> [];
            false -> "# Published Device Recipes\n"
        end,
    Timestamp =
        calendar:system_time_to_rfc3339(
            erlang:system_time(second),
            [{offset, "Z"}]
        ),
    append(Ledger, [
        Header,
        "\n## Published at ", Timestamp, "\n\n",
        "Signer: `", Address, "`.\n\n",
        "| Recipe ID | Device | Slug | Spec ID | Block |\n",
        "|---|---|---|---|---|\n"
    ]),
    record(Ledger, started, Address, Result);
record(Ledger, started, _Address, Result) ->
    #{ id := ID, device := Device, slug := Slug, spec := Spec } = Result,
    append(Ledger,
        ["| ", ID, " | ", Device, " | ", Slug, " | ", Spec, " | pending |\n"]),
    started.

append(Ledger, Lines) ->
    ok = file:write_file(Ledger, Lines, [append]).

flag(Name, [Name, Value | _], _Default) -> Value;
flag(Name, [_ | Rest], Default) -> flag(Name, Rest, Default);
flag(_Name, [], Default) -> Default.

fail(Format, Args) ->
    io:format(standard_error, "error: " ++ Format ++ "~n", Args),
    halt(1).
