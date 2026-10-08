%%% @doc This node's shard: whether it may answer for its org, and how it
%%% answers.
%%%
%%% macula refuses to advertise an org's procedure from a node the org has not
%%% delegated (D25). A delegation can arrive long after the service starts, so
%%% the responder keeps asking and advertises the moment it is granted; until
%%% then `status/0' says why not, in the same shape mcl_om reports a provider
%%% grant. A link that drops and comes back needs nothing from here: macula
%%% replays the advertisement on the respawned link.
%%%
%%% The mesh is the `io' functions given to `configure/3'.
-module(macula_rag_responder_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM_NAME, <<"io.macula">>).
-define(EMB, #{model => <<"nomic">>, dim => 768}).
-define(PROC, <<"acme/rag.query_shard_v1">>).

responder_test_() ->
    {foreach, local, fun setup/0, fun cleanup/1,
     [with("before a responder is registered, status says so", fun not_registered/1),
      with("a granted node advertises the org's procedure at once", fun granted_advertises/1),
      with("a missing delegation is reported, and nothing is advertised", fun not_granted/1),
      with("a grant that arrives later is advertised then, exactly once", fun late_grant/1),
      with("a query is answered by the registered callback", fun answers/1),
      with("a query made with another embedding is refused", fun refuses_other_embedding/1),
      with("hits below the contract's minimum are refused, not sent", fun refuses_bad_hits/1),
      with("the callback's own error is passed on", fun passes_callback_error/1),
      with("unregistering withdraws the advertisement", fun unregisters/1),
      with("with no confidential option the advertisement leaves macula's default",
           fun advertises_macula_default/1),
      with("a configured confidential mode reaches the advertisement", fun advertises_configured_mode/1),
      with("configure refuses a confidential value that is not a provider mode",
           fun refuses_unknown_mode/1),
      with("configure refuses required while macula names no KEM key", fun refuses_required_without_key/1)]}.

with(Title, Test) -> fun(Ctx) -> {Title, {timeout, 10, fun() -> Test(Ctx) end}} end.

%%------------------------------------------------------------------------------

not_registered(_Ctx) ->
    ?assertMatch(#{responder := not_registered}, macula_rag:status()).

granted_advertises(Ctx) ->
    grant(Ctx),
    ok = macula_rag:register_responder(fun(_Q, _O) -> {ok, []} end),
    ?assertEqual([?PROC], advertised(Ctx)),
    ?assertMatch(#{responder := granted}, macula_rag:status()).

not_granted(Ctx) ->
    deny(Ctx, {provider_authorization, {procedure_delegation, not_found}}),
    ok = macula_rag:register_responder(fun(_Q, _O) -> {ok, []} end),
    ?assertEqual([], advertised(Ctx)),
    ?assertMatch(#{responder := {not_granted, #{reason := {provider_authorization,
                                                           {procedure_delegation, not_found}},
                                               since_ms := _}}},
                 macula_rag:status()).

late_grant(Ctx) ->
    deny(Ctx, {provider_authorization, {procedure_delegation, not_found}}),
    ok = macula_rag:register_responder(fun(_Q, _O) -> {ok, []} end),
    timer:sleep(250),
    ?assertEqual([], advertised(Ctx)),
    grant(Ctx),
    ok = wait_until(fun() -> advertised(Ctx) =:= [?PROC] end, 3000),
    timer:sleep(400),
    ?assertEqual([?PROC], advertised(Ctx)),
    ?assertMatch(#{responder := granted}, macula_rag:status()).

answers(Ctx) ->
    grant(Ctx),
    Test = self(),
    ok = macula_rag:register_responder(
           fun(Query, Opts) ->
                   Test ! {asked, Query, Opts},
                   {ok, [#{id => <<"d1">>, score => 0.9, text => <<"x">>}]}
           end),
    Reply = macula_rag_responder:handle(wire(macula_rag_contract:query_shard(#{text => <<"q">>}, 3, ?EMB))),
    ?assertEqual({ok, #{shard_id => <<"s1">>, embedding => ?EMB,
                        hits => [#{<<"id">> => <<"d1">>, <<"score">> => 0.9, <<"text">> => <<"x">>}]}},
                 macula_rag_contract:parse(shard_answered, wire(Reply))),
    ?assertEqual({asked, #{<<"text">> => <<"q">>}, #{top_k => 3}},
                 receive {asked, _, _} = M -> M after 1000 -> none end).

refuses_other_embedding(Ctx) ->
    grant(Ctx),
    ok = macula_rag:register_responder(fun(_Q, _O) -> error(must_not_be_asked) end),
    Other = #{model => <<"minilm">>, dim => 384},
    ?assertEqual({error, embedding_mismatch},
                 macula_rag_responder:handle(wire(macula_rag_contract:query_shard(#{}, 3, Other)))).

refuses_bad_hits(Ctx) ->
    grant(Ctx),
    ok = macula_rag:register_responder(fun(_Q, _O) -> {ok, [#{id => <<"d1">>}]} end),
    ?assertEqual({error, malformed_hits},
                 macula_rag_responder:handle(wire(macula_rag_contract:query_shard(#{}, 3, ?EMB)))).

passes_callback_error(Ctx) ->
    grant(Ctx),
    ok = macula_rag:register_responder(fun(_Q, _O) -> {error, index_offline} end),
    ?assertEqual({error, index_offline},
                 macula_rag_responder:handle(wire(macula_rag_contract:query_shard(#{}, 3, ?EMB)))).

unregisters(Ctx) ->
    grant(Ctx),
    ok = macula_rag:register_responder(fun(_Q, _O) -> {ok, []} end),
    ok = macula_rag:unregister_responder(),
    ?assertEqual([?PROC], unadvertised(Ctx)),
    ?assertMatch(#{responder := not_registered}, macula_rag:status()),
    ?assertEqual({error, no_responder},
                 macula_rag_responder:handle(wire(macula_rag_contract:query_shard(#{}, 3, ?EMB)))).

%% The shard procedure's `confidential' (macula's provider modes) is the
%% service's to choose: `required' refuses a peer query in the clear. Absent,
%% nothing is passed and macula reads it as `preferred'.
advertises_macula_default(Ctx) ->
    grant(Ctx),
    ok = macula_rag:register_responder(fun(_Q, _O) -> {ok, []} end),
    ?assertEqual([#{}], advertised_opts(Ctx)).

advertises_configured_mode(Ctx) ->
    with_kem_advertise(enabled, fun() ->
        ok = reconfigure(Ctx, #{confidential => required}),
        grant(Ctx),
        ok = macula_rag:register_responder(fun(_Q, _O) -> {ok, []} end),
        ?assertEqual([#{confidential => required}], advertised_opts(Ctx))
    end).

refuses_unknown_mode(Ctx) ->
    ?assertEqual({error, {confidentiality, {not_a_mode, sealed}}},
                 reconfigure(Ctx, #{confidential => sealed})).

refuses_required_without_key(Ctx) ->
    with_kem_advertise(disabled, fun() ->
        ?assertEqual({error, {confidentiality, kem_advertise_disabled}},
                     reconfigure(Ctx, #{confidential => required}))
    end).

%%------------------------------------------------------------------------------
%% Fixture: the library started with a fake mesh
%%------------------------------------------------------------------------------

setup() ->
    %% A test that failed may have left its supervisor registered; one failure
    %% must not make every later setup fail with already_started.
    stopped(whereis(macula_rag_sup)),
    State = ets:new(responder_mesh, [public, bag]),
    true = ets:insert(State, {grant, {error, not_yet}}),
    {ok, Sup} = macula_rag_sup:start_link(),
    unlink(Sup),
    Ctx = #{state => State, sup => Sup},
    ok = reconfigure(Ctx, #{}),
    Ctx.

reconfigure(#{state := State}, Extra) ->
    macula_rag:configure(self(), crypto:hash(sha256, ?REALM_NAME),
                         Extra#{org => <<"acme">>, shard_id => <<"s1">>, realm_name => ?REALM_NAME,
                                embedding => ?EMB, grant_retry_ms => 100, io => io(State)}).

%% macula's own switch, read when the mode is checked.
with_kem_advertise(Switch, Test) ->
    Before = application:get_env(macula, kem_advertise),
    ok = application:set_env(macula, kem_advertise, Switch),
    try Test() after restored(Before) end.

restored(undefined) -> application:unset_env(macula, kem_advertise);
restored({ok, Value}) -> application:set_env(macula, kem_advertise, Value).

cleanup(#{state := State, sup := Sup}) ->
    Mon = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Mon, process, Sup, _} -> ok after 2000 -> ok end,
    macula_rag:forget_configuration(),
    ets:delete(State).

stopped(undefined) -> ok;
stopped(Sup) ->
    Mon = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Mon, process, Sup, _} -> ok after 2000 -> ok end.

io(State) ->
    #{provider_authorization => fun(_Pool, _Realm, _Proc) ->
                                        [{grant, G} | _] = lists:reverse(ets:lookup(State, grant)),
                                        G
                                end,
      advertise => fun(_Pool, _Realm, Proc, _Handler, Opts) ->
                           true = ets:insert(State, {advertised, Proc}),
                           true = ets:insert(State, {advertised_opts, Opts}), ok
                   end,
      unadvertise => fun(_Pool, _Realm, Proc) -> true = ets:insert(State, {unadvertised, Proc}), ok end,
      subscribe => fun(_Pool, _Realm, _Topic, _Pid) -> {ok, make_ref()} end,
      unsubscribe => fun(_Pool, _Ref) -> ok end,
      publish => fun(_Pool, _Realm, _Topic, _Payload) -> ok end,
      providers => fun(_Pool, _Realm, _Proc, _Timeout) -> {ok, []} end,
      call => fun(_Pool, _Realm, _Proc, _Payload, _Timeout, _Opts) -> {error, no_mesh} end,
      self_node_id => fun(_Pool) -> {ok, <<16#11:256>>} end}.

grant(#{state := State}) -> ets:insert(State, {grant, {ok, #{}}}).

deny(#{state := State}, Reason) -> ets:insert(State, {grant, {error, Reason}}).

advertised(#{state := State}) -> [P || {advertised, P} <- ets:lookup(State, advertised)].

advertised_opts(#{state := State}) -> [O || {advertised_opts, O} <- ets:lookup(State, advertised_opts)].

unadvertised(#{state := State}) -> [P || {unadvertised, P} <- ets:lookup(State, unadvertised)].

wire(Term) -> macula_record_cbor:decode(macula_record_cbor:encode(Term)).

wait_until(_Check, Left) when Left =< 0 -> timeout;
wait_until(Check, Left) -> waited(Check(), Check, Left).

waited(true, _Check, _Left) -> ok;
waited(false, Check, Left) -> timer:sleep(50), wait_until(Check, Left - 50).
