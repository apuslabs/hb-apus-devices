%%% @doc Self-documentation for the devices this node has loaded.
%%%
%%% The device reads the node's preloaded device index and serves, for each
%%% device, its Device-Specification body, the schema extracted from the
%%% loaded implementation's `-spec' declarations, and Device-Recipe messages
%%% published on Arweave. HTML pages are for people; `devices', `spec',
%%% `recipes' and `llms' return JSON or markdown for agents.
-module(dev_docs).
-implements(<<"docs@1.0">>).
-specification("docs/spec/docs.md").
-export([info/1, index/3, device/3, devices/3, spec/3, recipes/3, llms/3]).
-export([device_schema/3]).
-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(INDEX_KEY, <<"~meta@1.0/preloaded-devices-index">>).
-define(DEFAULT_GRAPHQL, <<"https://arweave.net/graphql">>).
-define(DEFAULT_GATEWAY, <<"https://arweave.net">>).
-define(RECIPE_TTL_MS, 300000).
-define(HIGHLIGHT, [
    <<"inference@1.0">>,
    <<"inference_receipt@1.0">>,
    <<"inference_measurement@1.0">>,
    <<"gpu_inventory@1.0">>,
    <<"sev_gpu@1.0">>,
    <<"agent@1.0">>,
    <<"docs@1.0">>
]).
-define(RECIPES_BY_SPEC,
    <<"query($specs:[String!]!,$after:String){transactions(first:100,after:$after,"
      "tags:[{name:\"type\",values:[\"Device-Recipe\"]},"
      "{name:\"recipe-for-device\",values:$specs}]){pageInfo{hasNextPage} "
      "edges{cursor node{id owner{address} tags{name value} block{timestamp}}}}}">>).
-define(RECIPES_BY_OWNER,
    <<"query($owners:[String!],$after:String){transactions(first:100,after:$after,"
      "owners:$owners,tags:[{name:\"type\",values:[\"Device-Recipe\"]}]){"
      "pageInfo{hasNextPage} "
      "edges{cursor node{id owner{address} tags{name value} block{timestamp}}}}}">>).

info(_) ->
    #{
        exports =>
            [
                <<"index">>,
                <<"device">>,
                <<"devices">>,
                <<"spec">>,
                <<"recipes">>,
                <<"llms">>,
                <<"device-schema">>
            ]
    }.

%%% Keys

%% @doc HTML index of every device in the node's preloaded index.
-spec index(#{ _ => _ }, #{ _ => _ }, map()) ->
    {ok, #{ body := binary(), 'content-type' := binary(), _ => _ }}.
index(_Base, _Req, Opts) ->
    Catalog = catalog(Opts),
    {Recipes, RecipeStatus} = recipe_index(Catalog, Opts),
    {Highlighted, Others} =
        lists:partition(fun(#{ highlight := H }) -> H end, Catalog),
    Body = [
        <<"<header><p class=\"crumb\">Node</p><h1>HyperBEAM Docs</h1>">>,
        <<"<p class=\"lede\">Documentation for the spec-loaded devices this "
          "node can resolve and run.</p>">>,
        node_facts(Catalog, RecipeStatus, Opts),
        <<"</header>">>,
        <<"<label class=\"filter\">Find a device"
          "<input id=\"q\" type=\"search\" placeholder=\"Filter by name...\" "
          "autocomplete=\"off\"></label>">>,
        device_section(<<"APUS devices">>, Highlighted, Recipes),
        device_section(<<"Core devices">>, Others, Recipes),
        agent_box(<<"Agents">>, [
            <<"curl -s \"$NODE/~docs@1.0/llms\"">>,
            <<"curl -s \"$NODE/~docs@1.0/devices\"">>
        ], Opts),
        filter_script()
    ],
    {ok, html(<<"HyperBEAM Docs">>, Body)}.

%% @doc HTML page for one device: specification, schema and recipes.
-spec device(#{ _ => _ }, #{ name => binary(), _ => _ }, map()) ->
    {ok, #{ body := binary(), status := integer(), _ => _ }}.
device(_Base, Req, Opts) ->
    with_device(Req, Opts, fun html_not_found/1,
        fun(Entry = #{ name := Name, spec_id := SpecID }) ->
            {Recipes, RecipeStatus} = recipe_index(catalog(Opts), Opts),
            DeviceRecipes = maps:get(Name, Recipes, []),
            Schema = device_schema(Name, Opts),
            Body = [
                <<"<header><p class=\"crumb\"><a href=\"index\">"
                  "&larr; All devices</a></p>">>,
                <<"<h1>">>, esc(Name), highlight_badge(Entry), <<"</h1>">>,
                <<"<dl class=\"facts\"><dt>Spec ID</dt><dd><code>">>,
                esc(SpecID), <<"</code></dd><dt>Spec signer</dt><dd>">>,
                join([[<<"<code>">>, esc(S), <<"</code>">>]
                    || S <- maps:get(signers, Entry)], <<" ">>),
                <<"</dd></dl></header>">>,
                agent_box(<<"Agents">>, [
                    [<<"curl -s \"$NODE/~docs@1.0/spec?name=">>, Name, <<"\"">>],
                    [<<"curl -s \"$NODE/~docs@1.0/device-schema?name=">>, Name,
                        <<"\"">>],
                    [<<"curl -s \"$NODE/~docs@1.0/recipes?name=">>, Name,
                        <<"\"">>]
                ], Opts),
                <<"<section id=\"spec\"><h2>Spec</h2><div class=\"md\">">>,
                md_to_html(strip_title(maps:get(spec_body, Entry), Name), 3),
                <<"</div></section>">>,
                <<"<section id=\"schema\"><h2>Schema</h2>">>,
                schema_html(Schema),
                <<"</section><section id=\"recipes\"><h2>Recipes</h2>">>,
                recipes_html(DeviceRecipes, RecipeStatus, Opts),
                <<"</section>">>
            ],
            {ok, html(Name, Body)}
        end).

%% @doc JSON list of devices with spec IDs, signers and recipe counts.
-spec devices(#{ _ => _ }, #{ _ => _ }, map()) ->
    {ok, #{ body := binary(), 'content-type' := binary(), _ => _ }}.
devices(_Base, _Req, Opts) ->
    Catalog = catalog(Opts),
    {Recipes, RecipeStatus} = recipe_index(Catalog, Opts),
    Devices =
        [
            #{
                <<"name">> => Name,
                <<"spec-id">> => SpecID,
                <<"spec-signers">> => maps:get(signers, Entry),
                <<"apus">> => maps:get(highlight, Entry),
                <<"summary">> => summary(maps:get(spec_body, Entry)),
                <<"recipes">> => length(maps:get(Name, Recipes, [])),
                <<"links">> => #{
                    <<"page">> => <<"/~docs@1.0/device?name=", Name/binary>>,
                    <<"spec">> => <<"/~docs@1.0/spec?name=", Name/binary>>,
                    <<"schema">> =>
                        <<"/~docs@1.0/device-schema?name=", Name/binary>>,
                    <<"native-schema">> => <<"/~", Name/binary, "/schema">>,
                    <<"recipes">> =>
                        <<"/~docs@1.0/recipes?name=", Name/binary>>
                }
            }
        ||
            Entry = #{ name := Name, spec_id := SpecID } <- Catalog
        ],
    {ok, text(<<"application/json">>, hb_json:encode(#{
        <<"node">> => node_address(Opts),
        <<"recipe-source">> => status_label(RecipeStatus),
        <<"devices">> => Devices
    }))}.

%% @doc The device's specification as markdown.
-spec spec(#{ _ => _ }, #{ name => binary(), _ => _ }, map()) ->
    {ok, #{ body := binary(), status := integer(), _ => _ }}.
spec(_Base, Req, Opts) ->
    with_device(Req, Opts, fun text_not_found/1,
        fun(#{ spec_body := Body }) ->
            {ok, text(<<"text/markdown; charset=utf-8">>, Body)}
        end).

%% @doc The device's extracted schema as JSON. `/~<device>/schema' serves the
%% same data, but a gateway may route a device's paths elsewhere (on
%% hb.apus.network, `/~inference@1.0/*' goes to the model runtime).
-spec device_schema(#{ _ => _ }, #{ name => binary(), _ => _ }, map()) ->
    {ok, #{ body := binary(), status := integer(), _ => _ }}.
device_schema(_Base, Req, Opts) ->
    with_device(Req, Opts, fun text_not_found/1,
        fun(#{ name := Name }) ->
            case device_schema(Name, Opts) of
                {ok, Schemas} ->
                    {ok, text(<<"application/json">>, hb_json:encode(#{
                        <<"device">> => Name,
                        <<"functions">> => jsonable(Schemas)
                    }))};
                {error, Reason} ->
                    {ok, (text(<<"application/json">>, hb_json:encode(#{
                        <<"device">> => Name,
                        <<"error">> => hb_util:bin(io_lib:format("~0P", [Reason, 8]))
                    })))#{ <<"status">> => 500 }}
            end
        end).

%% @doc The device's recipes as one markdown document.
-spec recipes(#{ _ => _ }, #{ name => binary(), _ => _ }, map()) ->
    {ok, #{ body := binary(), status := integer(), _ => _ }}.
recipes(_Base, Req, Opts) ->
    with_device(Req, Opts, fun text_not_found/1,
        fun(#{ name := Name }) ->
            {Recipes, RecipeStatus} = recipe_index(catalog(Opts), Opts),
            Sections =
                [
                    [
                        <<"<!-- recipe ">>, ID, <<" by ">>, Owner,
                        case Official of
                            true -> <<" (official)">>;
                            false -> <<>>
                        end,
                        <<" -->\n">>,
                        recipe_body(ID, Opts), <<"\n">>
                    ]
                ||
                    #{ id := ID, owner := Owner, official := Official }
                        <- maps:get(Name, Recipes, [])
                ],
            Header =
                case {Sections, RecipeStatus} of
                    {[], {error, Reason}} ->
                        [<<"<!-- recipes unavailable: ">>,
                            status_label({error, Reason}), <<" -->\n">>];
                    {[], _} ->
                        [<<"<!-- no recipes published for ">>, Name,
                            <<" -->\n">>];
                    _ -> []
                end,
            {ok, text(<<"text/markdown; charset=utf-8">>,
                iolist_to_binary([Header | Sections]))}
        end).

%% @doc A plain-text guide for agents that start from this node's URL.
-spec llms(#{ _ => _ }, #{ _ => _ }, map()) ->
    {ok, #{ body := binary(), 'content-type' := binary(), _ => _ }}.
llms(_Base, _Req, Opts) ->
    Catalog = catalog(Opts),
    Lines = [
        <<"# HyperBEAM node ">>, node_address(Opts), <<"\n\n">>,
        <<"Every device below is loaded on this node. Paths are relative to "
          "the URL you used to reach it.\n\n">>,
        <<"## Discover\n\n">>,
        <<"- `GET /~docs@1.0/devices`: JSON list of devices, spec IDs and "
          "links.\n">>,
        <<"- `GET /~docs@1.0/spec?name=<device>`: specification "
          "(markdown).\n">>,
        <<"- `GET /~docs@1.0/device-schema?name=<device>`: arguments and results "
          "extracted from the implementation's `-spec` (JSON). The device also "
          "serves it at `/~<device>/schema` with `accept: application/json` and "
          "`accept-bundle: true`, unless a gateway routes that path elsewhere.\n">>,
        <<"- `GET /~docs@1.0/recipes?name=<device>`: runnable curl examples "
          "(markdown).\n">>,
        <<"- `GET /~docs@1.0/index`: the same information as HTML.\n\n">>,
        <<"## Call\n\n">>,
        <<"`/~<device>/<key>?<param>=<value>` resolves `key` on the device. "
          "Send `accept: application/json` and `accept-bundle: true` to get "
          "JSON with nested values inline.\n\n">>,
        <<"## Devices\n\n">>,
        [
            [<<"- `">>, Name, <<"`">>,
                case maps:get(highlight, Entry) of
                    true -> <<" (APUS)">>;
                    false -> <<>>
                end,
                <<": ">>, summary(maps:get(spec_body, Entry)), <<"\n">>]
        ||
            Entry = #{ name := Name } <- Catalog
        ]
    ],
    {ok, text(<<"text/markdown; charset=utf-8">>, iolist_to_binary(Lines))}.

%%% Catalog

%% @doc Every device in the preloaded index with its specification. The
%% preloaded store is read-only, so the catalog is computed once per store.
catalog(Opts) ->
    case preloaded_opts(Opts) of
        undefined -> [];
        {Store, PreOpts} ->
            Key = {?MODULE, catalog, erlang:phash2(Store)},
            case persistent_term:get(Key, undefined) of
                undefined ->
                    Catalog = build_catalog(PreOpts, Opts),
                    persistent_term:put(Key, Catalog),
                    Catalog;
                Catalog ->
                    Catalog
            end
    end.

build_catalog(PreOpts, Opts) ->
    case hb_cache:read(?INDEX_KEY, PreOpts) of
        {ok, Index} ->
            Highlight = highlight_list(Opts),
            Entries =
                [
                    catalog_entry(
                        Name,
                        hb_util:bin(hb_cache:ensure_loaded(SpecRef, PreOpts)),
                        Highlight,
                        PreOpts
                    )
                ||
                    {Name, SpecRef} <- maps:to_list(Index),
                    is_binary(Name),
                    binary:match(Name, <<"@">>) =/= nomatch
                ],
            lists:sort(
                fun(A, B) -> sort_key(A, Highlight) =< sort_key(B, Highlight) end,
                Entries
            );
        _ ->
            []
    end.

catalog_entry(Name, SpecID, Highlight, PreOpts) ->
    {Signers, Body} =
        case hb_cache:read(SpecID, PreOpts) of
            {ok, Spec} ->
                Loaded = hb_cache:ensure_all_loaded(Spec, PreOpts),
                {committers(Loaded), spec_body(Loaded)};
            _ ->
                {[], <<>>}
        end,
    #{
        name => Name,
        spec_id => SpecID,
        signers => Signers,
        spec_body => Body,
        highlight => lists:member(Name, Highlight)
    }.

preloaded_opts(Opts) ->
    Node = maps:without([<<"cache-control">>, <<"only">>, <<"prefer">>], Opts),
    case hb_opts:get(preloaded_store, undefined, Node) of
        undefined -> undefined;
        Store -> {Store, Opts#{ <<"store">> => [Store] }}
    end.

committers(Spec) ->
    lists:usort(
        [
            hb_util:bin(Committer)
        ||
            #{ <<"committer">> := Committer } <-
                maps:values(maps:get(<<"commitments">>, Spec, #{}))
        ]
    ).

spec_body(Spec) ->
    case maps:get(<<"body">>, Spec, <<>>) of
        Body when is_binary(Body) ->
            case re:run(Body, <<"^\\s*@doc">>) of
                {match, _} -> edoc_to_md(Body);
                nomatch -> Body
            end;
        _ -> <<>>
    end.

%% @doc Core device specifications are EDoc moduledocs. Turn the common
%% markup into markdown: the `@doc' tag, `quoted'' names and simple HTML lists
%% and emphasis. Specs written in markdown pass through unchanged.
edoc_to_md(Body) ->
    lists:foldl(
        fun({Pattern, Replacement}, Acc) ->
            re:replace(Acc, Pattern, Replacement, [global, multiline, {return, binary}])
        end,
        Body,
        [
            {<<"^[ \\t]*@doc[ \\t]*">>, <<>>},
            {<<"^[ \\t]*@(end|author|copyright|since|see)\\b.*$">>, <<>>},
            {<<"`([^`'\\n]+)'">>, <<"`\\1`">>},
            {<<"\\s*<li>\\s*">>, <<"\n- ">>},
            {<<"</?(ul|ol|li|p|br)\\s*/?>">>, <<"\n">>},
            {<<"</?(em|i|b|strong)>">>, <<"**">>},
            {<<"</?(code|tt)>">>, <<"`">>}
        ]
    ).

highlight_list(Opts) ->
    case hb_opts:get(<<"docs-highlight-devices">>, ?HIGHLIGHT, Opts) of
        List when is_list(List) -> [hb_util:bin(D) || D <- List];
        _ -> ?HIGHLIGHT
    end.

sort_key(#{ name := Name }, Highlight) ->
    case lists:search(fun({_, N}) -> N =:= Name end,
            lists:zip(lists:seq(1, length(Highlight)), Highlight)) of
        {value, {Pos, _}} -> {0, Pos, Name};
        false -> {1, 0, Name}
    end.

with_device(Req, Opts, NotFound, Fun) ->
    Name = hb_util:bin(hb_ao:get(<<"name">>, Req, <<>>, Opts)),
    case lists:search(fun(#{ name := N }) -> N =:= Name end, catalog(Opts)) of
        {value, Entry} -> Fun(Entry);
        false -> NotFound(Name)
    end.

%% @doc Drop a leading `# <device>' heading: the page already shows the name.
strip_title(Body, Name) ->
    case re:run(Body, <<"^\\s*#[ \\t]+([^\\n]*)\\n">>, [{capture, [0, 1], binary}]) of
        {match, [Whole, Title]} ->
            case string:trim(Title) =:= Name of
                true -> binary:part(Body, byte_size(Whole), byte_size(Body) - byte_size(Whole));
                false -> Body
            end;
        nomatch -> Body
    end.

summary(<<>>) -> <<"No specification body.">>;
summary(Body) ->
    Lines = [string:trim(L) || L <- binary:split(Body, [<<"\r\n">>, <<"\n">>], [global])],
    Prose = lists:dropwhile(fun(L) -> L =:= <<>> orelse is_md_marker(L) end, Lines),
    case lists:takewhile(fun(L) -> L =/= <<>> andalso not is_md_marker(L) end, Prose) of
        [] -> <<"No summary.">>;
        Paragraph ->
            truncate(strip_inline(iolist_to_binary(join(Paragraph, <<" ">>))), 160)
    end.

is_md_marker(<<"#", _/binary>>) -> true;
is_md_marker(<<"|", _/binary>>) -> true;
is_md_marker(<<"```", _/binary>>) -> true;
is_md_marker(<<"<", _/binary>>) -> true;
is_md_marker(_) -> false.

strip_inline(Bin) ->
    re:replace(Bin, <<"[`*]">>, <<>>, [global, {return, binary}]).

truncate(Bin, Max) when byte_size(Bin) =< Max -> Bin;
truncate(Bin, Max) ->
    Cut = string:slice(Bin, 0, Max),
    <<(hb_util:bin(Cut))/binary, "...">>.

%%% Schemas

device_schema(Name, Opts) ->
    try
        Module = hb_device:message_to_device(#{ <<"device">> => Name }, Opts),
        hb_device_load:schema(Module, Opts)
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

schema_html({ok, Schemas}) when map_size(Schemas) == 0 ->
    <<"<p class=\"muted\">The implementation declares no <code>-spec</code> "
      "for its keys.</p>">>;
schema_html({ok, Schemas}) ->
    [
        [
            schema_function_html(Name, Arity, Fun)
        ||
            {Arity, Fun} <- lists:sort(maps:to_list(Arities))
        ]
    ||
        {Name, Arities} <- lists:sort(maps:to_list(Schemas))
    ] ++ [
        <<"<details><summary>Full extracted schema</summary><pre><code>">>,
        esc(hb_json:encode(jsonable(Schemas))),
        <<"</code></pre></details>">>
    ];
schema_html({error, Reason}) ->
    [<<"<p class=\"muted\">Schema unavailable: <code>">>,
        esc(hb_util:bin(io_lib:format("~0p", [Reason]))), <<"</code></p>">>].

schema_function_html(Name, Arity, #{ <<"args">> := Args, <<"return">> := Ret }) ->
    [
        <<"<article class=\"fn\"><h3><code>">>, esc(Name), <<"/">>,
        hb_util:bin(Arity), <<"</code></h3>">>,
        case Args of
            [BaseSchema, ReqSchema | _] ->
                [
                    keys_table(<<"Request parameters">>, ReqSchema),
                    keys_table(<<"Base keys">>, BaseSchema)
                ];
            _ ->
                <<>>
        end,
        <<"<p class=\"ret\"><strong>Returns</strong> <code>">>,
        esc(type_label(Ret)), <<"</code></p></article>">>
    ];
schema_function_html(Name, Arity, _Fun) ->
    [<<"<article class=\"fn\"><h3><code>">>, esc(Name), <<"/">>,
        hb_util:bin(Arity), <<"</code></h3></article>">>].

keys_table(Title, #{ <<"kind">> := <<"message">>, <<"keys">> := Keys } = Schema)
        when map_size(Keys) > 0 ->
    [
        <<"<h4>">>, Title, <<"</h4><div class=\"scroll\"><table><thead><tr>"
        "<th>Name</th><th>Required</th><th>Type</th></tr></thead><tbody>">>,
        [
            [
                <<"<tr><td><code>">>, esc(Key), <<"</code></td><td>">>,
                presence_badge(maps:get(<<"presence">>, KeySchema, <<>>)),
                <<"</td><td><code>">>,
                esc(type_label(maps:get(<<"type">>, KeySchema, #{}))),
                <<"</code></td></tr>">>
            ]
        ||
            {Key, KeySchema} <- lists:sort(maps:to_list(Keys))
        ],
        <<"</tbody></table></div>">>,
        case maps:is_key(<<"wildcard">>, Schema) of
            true -> <<"<p class=\"muted\">Other keys are passed through.</p>">>;
            false -> <<>>
        end
    ];
keys_table(_Title, _Schema) ->
    <<>>.

presence_badge(<<"required">>) -> <<"<span class=\"badge req\">required</span>">>;
presence_badge(<<"optional">>) -> <<"<span class=\"badge opt\">optional</span>">>;
presence_badge(Other) -> esc(hb_util:bin(Other)).

%% @doc A one-line rendering of an extracted type schema.
type_label(#{ <<"kind">> := <<"wildcard">> }) -> <<"_">>;
type_label(#{ <<"kind">> := <<"literal">>, <<"value">> := Value })
        when is_binary(Value) ->
    Value;
type_label(#{ <<"kind">> := <<"literal">>, <<"value">> := Value }) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
type_label(#{ <<"kind">> := <<"literal">>, <<"value">> := Value }) ->
    hb_util:bin(io_lib:format("~0p", [Value]));
type_label(#{ <<"kind">> := <<"union">>, <<"members">> := Members }) ->
    join([type_label(M) || M <- Members], <<" | ">>);
type_label(#{ <<"kind">> := <<"tuple">>, <<"items">> := Items }) ->
    [<<"{">>, join([type_label(I) || I <- Items], <<", ">>), <<"}">>];
type_label(#{ <<"kind">> := <<"message">>, <<"keys">> := Keys })
        when map_size(Keys) > 0 ->
    [<<"message(">>, join(lists:sort(maps:keys(Keys)), <<", ">>), <<")">>];
type_label(#{ <<"kind">> := <<"message">> }) -> <<"message">>;
type_label(#{ <<"kind">> := <<"list">>, <<"type">> := Type }) ->
    [<<"[">>, type_label(Type), <<"]">>];
type_label(#{ <<"kind">> := Kind }) -> hb_util:bin(Kind);
type_label(Other) -> hb_util:bin(io_lib:format("~0p", [Other])).

%% @doc Make an extracted schema JSON-encodable: arities become binary keys.
jsonable(Map) when is_map(Map) ->
    maps:from_list([{json_key(K), jsonable(V)} || {K, V} <- maps:to_list(Map)]);
jsonable(List) when is_list(List) -> [jsonable(V) || V <- List];
jsonable(Value) when is_binary(Value); is_number(Value); is_boolean(Value) ->
    Value;
jsonable(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
jsonable(Value) -> hb_util:bin(io_lib:format("~0p", [Value])).

json_key(Key) when is_binary(Key) -> Key;
json_key(Key) when is_integer(Key) -> integer_to_binary(Key);
json_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
json_key(Key) -> hb_util:bin(io_lib:format("~0p", [Key])).

%%% Recipes

%% @doc Device-Recipe messages for every device in the catalog, keyed by
%% device name. Cached for `RECIPE_TTL_MS'; gateway failures are returned as
%% the status and leave the previous result in place.
recipe_index(Catalog, Opts) ->
    Key = {?MODULE, recipes, erlang:phash2([N || #{ name := N } <- Catalog])},
    Now = erlang:system_time(millisecond),
    case persistent_term:get(Key, undefined) of
        {At, Result, Status} when Now - At < ?RECIPE_TTL_MS ->
            {Result, Status};
        Previous ->
            case fetch_recipes(Catalog, Opts) of
                {ok, Result} ->
                    persistent_term:put(Key, {Now, Result, {ok, Now}}),
                    {Result, {ok, Now}};
                {error, Reason} ->
                    Stale =
                        case Previous of
                            {_, OldResult, _} -> OldResult;
                            undefined -> #{}
                        end,
                    persistent_term:put(Key, {Now, Stale, {error, Reason}}),
                    {Stale, {error, Reason}}
            end
    end.

fetch_recipes([], _Opts) -> {ok, #{}};
fetch_recipes(Catalog, Opts) ->
    SpecIDs = [ID || #{ spec_id := ID } <- Catalog],
    Trusted = trusted_signers(Catalog, Opts),
    maybe
        {ok, BySpec} ?= graphql_all(?RECIPES_BY_SPEC, #{ <<"specs">> => SpecIDs }, Opts),
        {ok, ByOwner} ?= graphql_all(?RECIPES_BY_OWNER, #{ <<"owners">> => Trusted }, Opts),
        Nodes = maps:values(maps:from_list(
            [{maps:get(<<"id">>, N), N} || N <- BySpec ++ ByOwner])),
        {ok, assign_recipes(Catalog, [recipe(N) || N <- Nodes],
            configured_signers(Opts))}
    end.

%% @doc Attach each recipe to the device whose spec ID it names, or, for a
%% trusted author, to the device named in `primary-device'.
assign_recipes(Catalog, Recipes, Extra) ->
    maps:from_list(
        [
            {Name, sort_recipes(latest(SpecID,
                [
                    R#{ official => lists:member(Owner, Signers ++ Extra) }
                ||
                    R = #{ owner := Owner, for := For, primary := Primary }
                        <- Recipes,
                    For =:= SpecID orelse
                        (Primary =:= Name andalso
                            lists:member(Owner, Signers ++ Extra))
                ]))}
        ||
            #{ name := Name, spec_id := SpecID, signers := Signers } <- Catalog
        ]
    ).

%% @doc Keep one recipe per author and slug: a republished recipe replaces
%% the older one. Prefer the recipe bound to the current specification, then
%% the newest `published-at'.
latest(SpecID, Recipes) ->
    Ranked =
        lists:sort(
            fun(A, B) -> rank(SpecID, A) >= rank(SpecID, B) end,
            Recipes
        ),
    element(2, lists:foldl(
        fun(R = #{ owner := Owner, slug := Slug }, {Seen, Acc}) ->
            case lists:member({Owner, Slug}, Seen) of
                true -> {Seen, Acc};
                false -> {[{Owner, Slug} | Seen], [R | Acc]}
            end
        end,
        {[], []},
        Ranked
    )).

rank(SpecID, #{ for := For, published := Published }) ->
    {For =:= SpecID, Published}.

sort_recipes(Recipes) ->
    lists:sort(
        fun(A, B) ->
            {not maps:get(official, A), maps:get(title, A)} =<
                {not maps:get(official, B), maps:get(title, B)}
        end,
        Recipes
    ).

recipe(Node) ->
    Tags =
        maps:from_list(
            [
                {string:lowercase(maps:get(<<"name">>, T)), maps:get(<<"value">>, T)}
            ||
                T <- maps:get(<<"tags">>, Node, [])
            ]
        ),
    ID = maps:get(<<"id">>, Node),
    #{
        id => ID,
        owner => maps:get(<<"address">>, maps:get(<<"owner">>, Node, #{}), <<>>),
        for => maps:get(<<"recipe-for-device">>, Tags, <<>>),
        primary => maps:get(<<"primary-device">>, Tags, <<>>),
        title => maps:get(<<"title">>, Tags, maps:get(<<"slug">>, Tags, ID)),
        slug => maps:get(<<"slug">>, Tags, ID),
        published => published_at(Tags, Node),
        confirmed =>
            case maps:get(<<"block">>, Node, null) of
                #{ <<"timestamp">> := TS } when is_integer(TS) -> true;
                _ -> false
            end
    }.

published_at(Tags, Node) ->
    case catch binary_to_integer(maps:get(<<"published-at">>, Tags, <<>>)) of
        Seconds when is_integer(Seconds) -> Seconds;
        _ ->
            case maps:get(<<"block">>, Node, null) of
                #{ <<"timestamp">> := TS } when is_integer(TS) -> TS;
                _ -> 0
            end
    end.

trusted_signers(Catalog, Opts) ->
    lists:usort(
        lists:append([S || #{ signers := S, highlight := true } <- Catalog])
            ++ configured_signers(Opts)
    ).

configured_signers(Opts) ->
    Configured =
        case hb_opts:get(<<"docs-recipe-signers">>, [], Opts) of
            List when is_list(List) -> [hb_util:bin(S) || S <- List];
            Bin when is_binary(Bin) ->
                [string:trim(S) || S <- binary:split(Bin, <<",">>, [global])];
            _ -> []
        end,
    lists:usort([node_address(Opts) | Configured]) -- [<<>>].

graphql_all(Query, Vars, Opts) ->
    graphql_all(Query, Vars, undefined, [], 10, Opts).

graphql_all(_Query, _Vars, _After, Acc, 0, _Opts) ->
    {ok, Acc};
graphql_all(Query, Vars, After, Acc, Pages, Opts) ->
    Variables =
        case After of
            undefined -> Vars;
            _ -> Vars#{ <<"after">> => After }
        end,
    maybe
        {ok, #{ <<"data">> := #{ <<"transactions">> := Txs } }} ?=
            graphql(Query, Variables, Opts),
        Edges = maps:get(<<"edges">>, Txs, []),
        Nodes = [maps:get(<<"node">>, E) || E <- Edges],
        case {maps:get(<<"pageInfo">>, Txs, #{}), Edges} of
            {#{ <<"hasNextPage">> := true }, [_ | _]} ->
                Cursor = maps:get(<<"cursor">>, lists:last(Edges)),
                graphql_all(Query, Vars, Cursor, Acc ++ Nodes, Pages - 1, Opts);
            _ ->
                {ok, Acc ++ Nodes}
        end
    else
        {ok, Other} -> {error, {graphql_unexpected, Other}};
        {error, Reason} -> {error, Reason}
    end.

graphql(Query, Variables, Opts) ->
    URL = hb_util:bin(hb_opts:get(<<"docs-graphql-url">>, ?DEFAULT_GRAPHQL, Opts)),
    Body = hb_json:encode(#{ <<"query">> => Query, <<"variables">> => Variables }),
    case http_request(post, URL, Body) of
        {ok, 200, Response} -> {ok, hb_json:decode(Response)};
        {ok, Status, _Response} -> {error, {graphql_status, Status}};
        {error, Reason} -> {error, Reason}
    end.

%% @doc Fetch a URL with OTP's `httpc', verifying TLS against the system CA
%% store. Kept apart from `hb_http_client' so that recipe lookups do not depend
%% on the node's HTTP client configuration or metrics.
http_request(Method, URL, Body) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Request =
        case Method of
            get -> {hb_util:list(URL), []};
            post -> {hb_util:list(URL), [], "application/json", Body}
        end,
    HTTPOpts = [
        {timeout, 15000},
        {connect_timeout, 5000},
        {autoredirect, true},
        {ssl, [
            {verify, verify_peer},
            {cacerts, public_key:cacerts_get()},
            {customize_hostname_check,
                [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
        ]}
    ],
    try httpc:request(Method, Request, HTTPOpts, [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, Response}} -> {ok, Status, Response};
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% @doc A recipe's markdown body. Data on Arweave is immutable, so bodies are
%% cached for the life of the node once fetched.
recipe_body(ID, Opts) ->
    Key = {?MODULE, recipe_body, ID},
    case persistent_term:get(Key, undefined) of
        undefined ->
            Gateway = hb_util:bin(
                hb_opts:get(<<"docs-gateway-url">>, ?DEFAULT_GATEWAY, Opts)),
            URL = <<(string:trim(Gateway, trailing, "/"))/binary, "/raw/", ID/binary>>,
            case http_request(get, URL, <<>>) of
                {ok, 200, Body} ->
                    persistent_term:put(Key, Body),
                    Body;
                {ok, Status, _Body} ->
                    unavailable_body(ID, {status, Status});
                {error, Reason} ->
                    unavailable_body(ID, Reason)
            end;
        Body ->
            Body
    end.

unavailable_body(ID, Reason) ->
    iolist_to_binary(io_lib:format(
        "_Recipe `~s` is published but its data is not available from the "
        "gateway yet (~0P)._~n", [ID, Reason, 6])).

%%% HTML

recipes_html([], {error, Reason}, _Opts) ->
    [<<"<p class=\"muted\">Recipes could not be loaded from the gateway: "
       "<code>">>, esc(status_label({error, Reason})), <<"</code></p>">>];
recipes_html([], _Status, _Opts) ->
    <<"<p class=\"muted\">No Device-Recipe messages have been published for "
      "this device's specification yet.</p>">>;
recipes_html(Recipes, _Status, Opts) ->
    [
        [
            <<"<article class=\"recipe\"><header><h3>">>, esc(Title),
            <<"</h3><p class=\"muted\">">>,
            case Official of
                true -> <<"<span class=\"badge req\">official</span> ">>;
                false -> <<"<span class=\"badge opt\">community</span> ">>
            end,
            case Confirmed of
                true -> <<>>;
                false -> <<"<span class=\"badge opt\">pending</span> ">>
            end,
            <<"by <code>">>, esc(short(Owner)),
            <<"</code> &middot; <a href=\"https://arweave.net/">>, ID,
            <<"\" rel=\"noopener\">recipe transaction</a></p></header>"
              "<div class=\"md\">">>,
            md_to_html(strip_title(recipe_body(ID, Opts), Title), 3),
            <<"</div></article>">>
        ]
    ||
        #{ id := ID, title := Title, owner := Owner, official := Official,
            confirmed := Confirmed } <- Recipes
    ].

device_section(_Title, [], _Recipes) -> <<>>;
device_section(Title, Entries, Recipes) ->
    [
        <<"<section class=\"devices\"><h2>">>, Title,
        <<" <span class=\"count\">">>, integer_to_binary(length(Entries)),
        <<" devices</span></h2><ul class=\"grid\">">>,
        [
            [
                <<"<li data-name=\"">>, esc(Name), <<"\"><a href=\"device?name=">>,
                uri_escape(Name), <<"\"><strong>">>, esc(Name), <<"</strong>">>,
                <<"<span>">>, esc(summary(maps:get(spec_body, Entry))),
                <<"</span><em>">>,
                recipe_count(length(maps:get(Name, Recipes, []))),
                <<"</em></a></li>">>
            ]
        ||
            Entry = #{ name := Name } <- Entries
        ],
        <<"</ul></section>">>
    ].

recipe_count(0) -> <<"no recipes">>;
recipe_count(1) -> <<"1 recipe">>;
recipe_count(N) -> [integer_to_binary(N), <<" recipes">>].

node_facts(Catalog, RecipeStatus, Opts) ->
    [
        <<"<dl class=\"facts\"><dt>Node address</dt><dd><code>">>,
        esc(node_address(Opts)), <<"</code></dd><dt>Loaded devices</dt><dd>">>,
        integer_to_binary(length(Catalog)), <<"</dd><dt>Recipes</dt><dd>">>,
        esc(status_label(RecipeStatus)), <<"</dd></dl>">>
    ].

agent_box(Title, Commands, Opts) ->
    PublicURL = hb_util:bin(
        hb_opts:get(<<"docs-public-url">>, <<"https://hb.apus.network">>, Opts)),
    [
        <<"<aside class=\"agents\"><h2>">>, Title, <<"</h2><pre><code>">>,
        <<"NODE=">>, esc(PublicURL), <<"\n">>,
        join([esc(iolist_to_binary(C)) || C <- Commands], <<"\n">>),
        <<"</code></pre></aside>">>
    ].

highlight_badge(#{ highlight := true }) ->
    <<" <span class=\"badge req\">APUS</span>">>;
highlight_badge(_) -> <<>>.

status_label({ok, At}) ->
    Seconds = (erlang:system_time(millisecond) - At) div 1000,
    iolist_to_binary(io_lib:format(
        "Device-Recipe messages from Arweave GraphQL, refreshed ~ps ago",
        [Seconds]));
status_label({error, Reason}) ->
    iolist_to_binary(io_lib:format("gateway error: ~0P", [Reason, 8])).

html_not_found(Name) ->
    {ok, (html(<<"Device not found">>, [
        <<"<header><p class=\"crumb\"><a href=\"index\">&larr; All devices</a>"
          "</p><h1>Device not found</h1></header><p>This node has not loaded "
          "<code>">>, esc(Name), <<"</code>.</p>">>
    ]))#{ <<"status">> => 404 }}.

text_not_found(Name) ->
    {ok, (text(<<"text/plain; charset=utf-8">>,
        <<"Device not loaded on this node: ", Name/binary, "\n">>))#{
            <<"status">> => 404
        }}.

text(ContentType, Body) ->
    #{
        <<"status">> => 200,
        <<"content-type">> => ContentType,
        <<"cache-control">> => [<<"no-store">>],
        <<"body">> => Body
    }.

html(Title, Body) ->
    text(<<"text/html; charset=utf-8">>, iolist_to_binary([
        <<"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
          "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
          "<title>">>, esc(Title), <<"</title><style>">>, css(),
        <<"</style></head><body><main>">>, Body,
        <<"</main></body></html>">>
    ])).

css() ->
    <<":root{color-scheme:light dark;--bg:#fbfafb;--fg:#1d1d1f;--muted:#6b6b73;"
      "--line:#e3e1e6;--card:#fff;--code:#f2f1f4;--accent:#2f6f4f;--warn:#8a5a00}"
      "@media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#ececf0;"
      "--muted:#9a9aa3;--line:#2c2c31;--card:#1b1b1f;--code:#232328;"
      "--accent:#7fc8a0;--warn:#e6b450}}"
      "*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);"
      "font:16px/1.55 system-ui,-apple-system,'Segoe UI',sans-serif}"
      "main{max-width:980px;margin:0 auto;padding:32px 20px 64px}"
      "a{color:var(--accent)}h1{font-size:2rem;margin:.2em 0}"
      "h2{margin-top:2.2em;font-size:1.35rem}h3{font-size:1.05rem}"
      ".crumb{margin:0;color:var(--muted);font-size:.9rem}"
      ".lede{color:var(--muted);margin-top:0}"
      ".facts{display:grid;grid-template-columns:max-content 1fr;gap:4px 16px;"
      "font-size:.9rem}.facts dt{color:var(--muted)}.facts dd{margin:0;"
      "overflow-wrap:anywhere}"
      ".filter{display:block;margin:24px 0 8px;color:var(--muted);font-size:.9rem}"
      ".filter input{display:block;width:100%;margin-top:6px;padding:10px 12px;"
      "border:1px solid var(--line);border-radius:8px;background:var(--card);"
      "color:var(--fg);font:inherit}"
      ".count{color:var(--muted);font-weight:400;font-size:.9rem}"
      ".grid{list-style:none;padding:0;display:grid;"
      "grid-template-columns:repeat(auto-fill,minmax(min(260px,100%),1fr));gap:12px}"
      ".grid a{display:flex;flex-direction:column;gap:4px;height:100%;"
      "padding:14px;border:1px solid var(--line);border-radius:10px;"
      "background:var(--card);color:var(--fg);text-decoration:none}"
      ".grid a:hover{border-color:var(--accent)}.grid span{color:var(--muted);"
      "font-size:.88rem}.grid em{color:var(--muted);font-size:.8rem;font-style:normal}"
      "code{font:.88em ui-monospace,SFMono-Regular,Menlo,monospace;"
      "background:var(--code);padding:.1em .3em;border-radius:4px}"
      "pre{background:var(--code);padding:14px;border-radius:8px;overflow-x:auto}"
      "pre code{background:none;padding:0}"
      ".scroll{overflow-x:auto}table{border-collapse:collapse;width:100%;"
      "font-size:.92rem}th,td{text-align:left;padding:6px 10px;"
      "border-bottom:1px solid var(--line);vertical-align:top}"
      ".badge{display:inline-block;font-size:.75rem;padding:1px 8px;"
      "border-radius:999px;border:1px solid var(--line);vertical-align:middle}"
      ".badge.req{color:var(--accent);border-color:var(--accent)}"
      ".badge.opt{color:var(--muted)}.muted{color:var(--muted)}"
      ".agents{margin-top:24px;border:1px solid var(--line);border-radius:10px;"
      "padding:4px 16px 8px;background:var(--card)}.agents h2{margin-top:12px;"
      "font-size:1rem}"
      ".fn,.recipe{border-top:1px solid var(--line);padding-top:8px;margin-top:16px}"
      ".fn h4{margin:12px 0 4px;font-size:.9rem;color:var(--muted)}"
      "details{margin-top:16px}summary{cursor:pointer;color:var(--muted)}"
      ".md h2,.md h3,.md h4{margin-top:1.4em}"
      "@media (max-width:600px){main{padding:20px 14px 48px}h1{font-size:1.6rem}"
      ".facts{grid-template-columns:1fr}}">>.

filter_script() ->
    <<"<script>(function(){var q=document.getElementById('q');if(!q)return;"
      "q.addEventListener('input',function(){var v=q.value.toLowerCase();"
      "document.querySelectorAll('.grid li').forEach(function(li){"
      "li.style.display=li.dataset.name.indexOf(v)>=0?'':'none';});});})();"
      "</script>">>.

node_address(Opts) ->
    case hb_opts:get(priv_wallet, no_viable_wallet, Opts) of
        no_viable_wallet -> <<>>;
        Wallet -> hb_util:human_id(ar_wallet:to_address(Wallet))
    end.

short(Address) when byte_size(Address) > 12 ->
    <<(binary:part(Address, 0, 6))/binary, "...",
        (binary:part(Address, byte_size(Address) - 4, 4))/binary>>;
short(Address) -> Address.

uri_escape(Bin) -> hb_util:bin(uri_string:quote(Bin)).

esc(Bin) when is_binary(Bin) ->
    lists:foldl(
        fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
        Bin,
        [
            {<<"&">>, <<"&amp;">>},
            {<<"<">>, <<"&lt;">>},
            {<<">">>, <<"&gt;">>},
            {<<"\"">>, <<"&quot;">>},
            {<<"'">>, <<"&#39;">>}
        ]
    );
esc(Other) -> esc(iolist_to_binary(Other)).

join([], _Sep) -> [];
join([H | T], Sep) -> [H | [[Sep, X] || X <- T]].

%%% Markdown

%% @doc Render the markdown used in specs and recipes: ATX headings, fenced
%% code, pipe tables, lists and paragraphs with inline code, bold and links.
%% Headings are shifted so that `#' renders at `Top' + 1.
md_to_html(MD, Top) ->
    Lines = binary:split(MD, [<<"\r\n">>, <<"\n">>], [global]),
    iolist_to_binary(md_blocks(Lines, Top, [])).

md_blocks([], _Top, Acc) ->
    lists:reverse(Acc);
md_blocks([Line | Rest], Top, Acc) ->
    Trimmed = string:trim(Line),
    case Trimmed of
        <<>> ->
            md_blocks(Rest, Top, Acc);
        <<"```", Lang/binary>> ->
            {Code, Rest2} = take_fence(Rest, []),
            Block = [<<"<pre><code data-lang=\"">>, esc(string:trim(Lang)),
                <<"\">">>, esc(Code), <<"</code></pre>">>],
            md_blocks(Rest2, Top, [Block | Acc]);
        <<"#", _/binary>> ->
            {Level, Text} = heading(Trimmed, 0),
            Tag = integer_to_binary(min(6, Level + Top - 1)),
            Block = [<<"<h">>, Tag, <<">">>, inline(Text), <<"</h">>, Tag, <<">">>],
            md_blocks(Rest, Top, [Block | Acc]);
        <<"|", _/binary>> ->
            {Rows, Rest2} = take_while(fun is_table_line/1, [Line | Rest]),
            md_blocks(Rest2, Top, [table(Rows) | Acc]);
        _ ->
            case list_item(Trimmed) of
                {Kind, _} ->
                    {Items, Rest2} =
                        take_while(
                            fun(L) -> list_item(string:trim(L)) =/= false
                                orelse is_continuation(L) end,
                            [Line | Rest]
                        ),
                    md_blocks(Rest2, Top, [list_html(Kind, Items) | Acc]);
                false ->
                    {Para, Rest2} = take_while(fun is_paragraph_line/1, [Line | Rest]),
                    Text = join([string:trim(P) || P <- Para], <<" ">>),
                    md_blocks(Rest2, Top, [[<<"<p>">>, inline(iolist_to_binary(Text)),
                        <<"</p>">>] | Acc])
            end
    end.

take_fence([], Acc) -> {join(lists:reverse(Acc), <<"\n">>), []};
take_fence([Line | Rest], Acc) ->
    case string:trim(Line) of
        <<"```", _/binary>> -> {join(lists:reverse(Acc), <<"\n">>), Rest};
        _ -> take_fence(Rest, [Line | Acc])
    end.

take_while(Pred, Lines) -> lists:splitwith(Pred, Lines).

heading(<<"#", Rest/binary>>, N) -> heading(Rest, N + 1);
heading(Rest, N) -> {N, string:trim(Rest)}.

is_table_line(Line) ->
    case string:trim(Line) of
        <<"|", _/binary>> -> true;
        _ -> false
    end.

is_paragraph_line(Line) ->
    case string:trim(Line) of
        <<>> -> false;
        <<"#", _/binary>> -> false;
        <<"```", _/binary>> -> false;
        <<"|", _/binary>> -> false;
        Trimmed -> list_item(Trimmed) =:= false
    end.

is_continuation(<<"  ", Rest/binary>>) -> string:trim(Rest) =/= <<>>;
is_continuation(_) -> false.

list_item(<<"- ", Text/binary>>) -> {ul, Text};
list_item(<<"* ", Text/binary>>) -> {ul, Text};
list_item(Line) ->
    case re:run(Line, <<"^[0-9]+\\. (.*)$">>, [{capture, all_but_first, binary}]) of
        {match, [Text]} -> {ol, Text};
        nomatch -> false
    end.

list_html(Kind, Lines) ->
    Items = group_items(Lines, []),
    Tag = atom_to_binary(Kind, utf8),
    [<<"<">>, Tag, <<">">>,
        [[<<"<li>">>, inline(I), <<"</li>">>] || I <- Items],
        <<"</">>, Tag, <<">">>].

group_items([], Acc) -> lists:reverse(Acc);
group_items([Line | Rest], Acc) ->
    case list_item(string:trim(Line)) of
        {_, Text} -> group_items(Rest, [Text | Acc]);
        false ->
            case Acc of
                [Prev | AccRest] ->
                    group_items(Rest,
                        [<<Prev/binary, " ", (string:trim(Line))/binary>> | AccRest]);
                [] -> group_items(Rest, [string:trim(Line)])
            end
    end.

table(Rows) ->
    Cells = [split_row(R) || R <- Rows, not is_separator_row(R)],
    case Cells of
        [] -> <<>>;
        [Head | Body] ->
            [
                <<"<div class=\"scroll\"><table><thead><tr>">>,
                [[<<"<th>">>, inline(C), <<"</th>">>] || C <- Head],
                <<"</tr></thead><tbody>">>,
                [[<<"<tr>">>, [[<<"<td>">>, inline(C), <<"</td>">>] || C <- Row],
                    <<"</tr>">>] || Row <- Body],
                <<"</tbody></table></div>">>
            ]
    end.

split_row(Row) ->
    Inner = string:trim(string:trim(Row), both, "|"),
    [string:trim(C) || C <- binary:split(Inner, <<"|">>, [global])].

is_separator_row(Row) ->
    re:run(string:trim(Row), <<"^\\|?[\\s:|-]+\\|?$">>) =/= nomatch.

%% @doc Escape a line, then apply inline code, bold and links. Code spans are
%% rendered first and protected from the other rules.
inline(Text) ->
    Parts = re:split(Text, <<"(`[^`]+`)">>, [{return, binary}, trim]),
    iolist_to_binary(
        [
            case P of
                <<"`", _/binary>> when byte_size(P) >= 2 ->
                    [<<"<code>">>, esc(binary:part(P, 1, byte_size(P) - 2)),
                        <<"</code>">>];
                _ ->
                    links(bold(esc(P)))
            end
        ||
            P <- Parts
        ]
    ).

bold(Bin) ->
    re:replace(Bin, <<"\\*\\*([^*]+)\\*\\*">>, <<"<strong>\\1</strong>">>,
        [global, {return, binary}]).

links(Bin) ->
    re:replace(Bin, <<"\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)">>,
        <<"<a href=\"\\2\" rel=\"noopener\">\\1</a>">>,
        [global, {return, binary}]).

%%% Tests

md_render_test() ->
    HTML = md_to_html(<<
        "# Title\n\nSome `code` and **bold** [link](https://arweave.net).\n\n"
        "| Key | Use |\n|---|---|\n| `a` | b |\n\n"
        "- one\n- two\n  more\n\n"
        "```bash\ncurl -s \"$HB/x\" | head\n```\n"
    >>, 2),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"<h2>Title</h2>">>)),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"<code>code</code>">>)),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"<strong>bold</strong>">>)),
    ?assertNotEqual(nomatch,
        binary:match(HTML, <<"<a href=\"https://arweave.net\" rel=\"noopener\">link</a>">>)),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"<td><code>a</code></td>">>)),
    ?assertNotEqual(nomatch, binary:match(HTML, <<"<li>two more</li>">>)),
    ?assertNotEqual(nomatch,
        binary:match(HTML, <<"curl -s &quot;$HB/x&quot; | head">>)).

md_escapes_html_test() ->
    HTML = md_to_html(<<"<script>alert(1)</script>">>, 2),
    ?assertEqual(nomatch, binary:match(HTML, <<"<script>">>)).

type_label_test() ->
    Ret = #{
        <<"kind">> => <<"union">>,
        <<"members">> => [
            #{ <<"kind">> => <<"tuple">>, <<"items">> => [
                #{ <<"kind">> => <<"literal">>, <<"value">> => ok },
                #{ <<"kind">> => <<"message">>, <<"keys">> => #{} }
            ]},
            #{ <<"kind">> => <<"tuple">>, <<"items">> => [
                #{ <<"kind">> => <<"literal">>, <<"value">> => error },
                #{ <<"kind">> => <<"wildcard">> }
            ]}
        ]
    },
    ?assertEqual(<<"{ok, message} | {error, _}">>, iolist_to_binary(type_label(Ret))),
    ?assertEqual(<<"ok">>,
        iolist_to_binary(type_label(#{ <<"kind">> => <<"literal">>, <<"value">> => <<"ok">> }))).

markdown_spec_keeps_apostrophes_test() ->
    Spec = #{ <<"body">> => <<"# x@1.0\n\nThe `a` runtime's `b` value.\n">> },
    ?assertEqual(<<"# x@1.0\n\nThe `a` runtime's `b` value.\n">>, spec_body(Spec)),
    ?assertEqual(<<"\nThe `a` runtime's `b` value.\n">>,
        strip_title(spec_body(Spec), <<"x@1.0">>)).

edoc_summary_test() ->
    Body = edoc_to_md(<<"@doc Codec for `ans104@1.0' items, converting\n"
        "between <em>TABMs</em> and bundles.\n\nMore.\n">>),
    ?assertEqual(<<"Codec for ans104@1.0 items, converting between TABMs and bundles.">>,
        summary(Body)).

summary_test() ->
    ?assertEqual(<<"Self-documentation for loaded devices.">>,
        summary(<<"# docs@1.0\n\nSelf-documentation for `loaded` devices.\n">>)).

assign_recipes_test() ->
    Catalog = [
        #{ name => <<"a@1.0">>, spec_id => <<"SPEC-A">>, signers => [<<"S">>] },
        #{ name => <<"b@1.0">>, spec_id => <<"SPEC-B">>, signers => [<<"S">>] }
    ],
    R = fun(ID, Owner, For, Primary, Slug, Published) ->
        #{ id => ID, owner => Owner, for => For, primary => Primary,
            title => Slug, slug => Slug, published => Published,
            confirmed => true }
    end,
    Recipes = [
        R(<<"1">>, <<"S">>, <<"SPEC-A">>, <<"a@1.0">>, <<"x">>, 10),
        R(<<"2">>, <<"X">>, <<"SPEC-A">>, <<"a@1.0">>, <<"y">>, 10),
        R(<<"3">>, <<"S">>, <<"OLD-SPEC">>, <<"b@1.0">>, <<"z">>, 10),
        R(<<"4">>, <<"X">>, <<"OLD-SPEC">>, <<"b@1.0">>, <<"w">>, 10),
        R(<<"5">>, <<"S">>, <<"OLD-SPEC">>, <<"a@1.0">>, <<"x">>, 20),
        R(<<"6">>, <<"S">>, <<"OLD-SPEC">>, <<"b@1.0">>, <<"z">>, 30)
    ],
    Assigned = assign_recipes(Catalog, Recipes, []),
    ?assertEqual([{<<"1">>, true}, {<<"2">>, false}],
        [{ID, O} || #{ id := ID, official := O } <- maps:get(<<"a@1.0">>, Assigned)]),
    ?assertEqual([{<<"6">>, true}],
        [{ID, O} || #{ id := ID, official := O } <- maps:get(<<"b@1.0">>, Assigned)]).
