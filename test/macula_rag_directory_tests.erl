%%% @doc What this node knows of the org's shards, and what it tells them.
-module(macula_rag_directory_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM_NAME, <<"io.macula">>).
-define(EMB, #{model => <<"nomic">>, dim => 768}).
-define(EMB_PATTERN, #{model := <<"nomic">>, dim := 768}).
-define(ME, <<16#11:256>>).
-define(A, <<16#AA:256>>).

directory_test_() ->
    {foreach, local, fun setup/0, fun cleanup/1,
     [with("a summary belongs to the node macula verified, not to what it claims",
           fun summary_is_the_publishers/1),
      with("a withdrawal forgets the shard", fun withdrawal_forgets/1),
      with("a summary nobody republished goes stale", fun stale_summary_is_absent/1),
      with("a malformed summary is ignored", fun malformed_is_ignored/1),
      with("this node's summary is published and kept under its own id", fun own_summary/1),
      with("this node's summary is republished until withdrawn", fun own_summary_republished/1),
      with("withdrawing publishes the withdrawal and forgets this node's summary", fun own_withdrawn/1),
      with("reconfiguring unsubscribes on the pool the subscription was made on",
           fun rebind_unsubscribes_the_old_pool/1),
      with("a subscription macula drops is made again", fun dropped_subscription_returns/1)]}.

with(Title, Test) -> fun(Ctx) -> {Title, {timeout, 10, fun() -> Test(Ctx) end}} end.

%%------------------------------------------------------------------------------

summary_is_the_publishers(Ctx) ->
    hear(Ctx, shard_summarized, ?A, summarized(<<"claims-to-be-someone">>)),
    ?assertMatch({ok, #{shard_id := <<"claims-to-be-someone">>, embedding := ?EMB_PATTERN}},
                 macula_rag_directory:summary(?A)),
    ?assertEqual(none, macula_rag_directory:summary(<<16#BB:256>>)),
    ?assertMatch([#{node_id := _}], macula_rag:shards()),
    [#{node_id := NodeId}] = macula_rag:shards(),
    ?assertEqual(binary:encode_hex(?A, lowercase), NodeId).

withdrawal_forgets(Ctx) ->
    hear(Ctx, shard_summarized, ?A, summarized(<<"a">>)),
    hear(Ctx, shard_withdrawn, ?A, macula_rag_contract:shard_withdrawn(<<"a">>, 1)),
    ?assertEqual(none, macula_rag_directory:summary(?A)).

stale_summary_is_absent(Ctx) ->
    hear(Ctx, shard_summarized, ?A, summarized(<<"a">>)),
    ?assertMatch({ok, _}, macula_rag_directory:summary(?A)),
    %% summary_republish_ms is 100 in this fixture: stale after 300 ms.
    timer:sleep(450),
    ?assertEqual(none, macula_rag_directory:summary(?A)),
    ?assertEqual([], [S || #{node_id := N} = S <- macula_rag:shards(), N =/= hex(?ME)]).

malformed_is_ignored(Ctx) ->
    hear(Ctx, shard_summarized, ?A, #{shard_id => 7}),
    ?assertEqual(none, macula_rag_directory:summary(?A)).

own_summary(Ctx) ->
    ok = macula_rag:advertise([<<"topic/a">>], <<1, 2, 3>>),
    [{_Topic, Summary} | _] = published(Ctx, shard_summarized),
    ?assertMatch({ok, #{shard_id := <<"me">>, embedding := ?EMB_PATTERN, topics := [<<"topic/a">>],
                        bloom := <<1, 2, 3>>}},
                 macula_rag_contract:parse(shard_summarized, wire(Summary))),
    ?assertMatch({ok, #{shard_id := <<"me">>}}, macula_rag_directory:summary(?ME)),
    ?assertMatch(#{advertised := true}, macula_rag:status()).

own_summary_republished(Ctx) ->
    ok = macula_rag:advertise([], <<>>),
    timer:sleep(350),
    ?assert(length(published(Ctx, shard_summarized)) >= 3),
    ok = macula_rag:withdraw(),
    N = length(published(Ctx, shard_summarized)),
    timer:sleep(300),
    ?assertEqual(N, length(published(Ctx, shard_summarized))).

own_withdrawn(Ctx) ->
    ok = macula_rag:advertise([], <<>>),
    ok = macula_rag:withdraw(),
    ?assertMatch([{_, #{shard_id := <<"me">>}}], published(Ctx, shard_withdrawn)),
    ?assertEqual(none, macula_rag_directory:summary(?ME)),
    ?assertMatch(#{advertised := false}, macula_rag:status()).

rebind_unsubscribes_the_old_pool(#{state := State} = Ctx) ->
    OldPool = self(),
    NewPool = spawn(fun() -> receive stop -> ok end end),
    ok = macula_rag:configure(NewPool, crypto:hash(sha256, ?REALM_NAME), opts(State)),
    Unsubscribed = [Pool || {unsubscribed, Pool, _Ref} <- ets:tab2list(State)],
    ?assertEqual([OldPool, OldPool], Unsubscribed),
    ?assertEqual(2, length([Ref || {subscribed, P, _Topic, Ref} <- ets:tab2list(State), P =:= NewPool])),
    NewPool ! stop,
    _ = Ctx.

dropped_subscription_returns(#{state := State} = Ctx) ->
    [{subscribed, _, _, Ref} | _] = [S || {subscribed, _, _, _} = S <- ets:tab2list(State)],
    Before = length([x || {subscribed, _, _, _} <- ets:tab2list(State)]),
    whereis(macula_rag_directory) ! {macula_event_gone, Ref, link_down},
    timer:sleep(1300),
    ?assert(length([x || {subscribed, _, _, _} <- ets:tab2list(State)]) > Before),
    _ = Ctx.

%%------------------------------------------------------------------------------
%% Fixture
%%------------------------------------------------------------------------------

setup() ->
    stopped(whereis(macula_rag_sup)),
    State = ets:new(directory_mesh, [public, bag]),
    {ok, Sup} = macula_rag_sup:start_link(),
    unlink(Sup),
    ok = macula_rag:configure(self(), crypto:hash(sha256, ?REALM_NAME), opts(State)),
    #{state => State, sup => Sup}.

opts(State) ->
    #{org => <<"acme">>, shard_id => <<"me">>, realm_name => ?REALM_NAME, embedding => ?EMB,
      summary_republish_ms => 100, io => io(State)}.

cleanup(#{state := State, sup := Sup}) ->
    stopped(Sup),
    macula_rag:forget_configuration(),
    ets:delete(State).

stopped(undefined) -> ok;
stopped(Sup) ->
    Mon = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Mon, process, Sup, _} -> ok after 2000 -> ok end.

io(State) ->
    #{subscribe => fun(Pool, _Realm, Topic, _Pid) ->
                           Ref = make_ref(),
                           true = ets:insert(State, {subscribed, Pool, Topic, Ref}),
                           {ok, Ref}
                   end,
      unsubscribe => fun(Pool, Ref) -> true = ets:insert(State, {unsubscribed, Pool, Ref}), ok end,
      publish => fun(_Pool, _Realm, Topic, Payload) ->
                         true = ets:insert(State, {published, Topic, Payload}), ok
                 end,
      self_node_id => fun(_Pool) -> {ok, ?ME} end}.

%% A fact as macula delivers it to the directory: on the subscription made for
%% it, through the codec, with the verified publisher in the meta.
hear(#{state := State}, Fact, Publisher, Payload) ->
    Topic = macula_rag_contract:topic(?REALM_NAME, <<"acme">>, Fact),
    [Ref | _] = [R || {subscribed, _, T, R} <- ets:tab2list(State), T =:= Topic],
    whereis(macula_rag_directory) ! {macula_event, Ref, Topic, wire(Payload),
                                    #{publisher => Publisher, delivered_via => direct}},
    _ = sys:get_state(macula_rag_directory),
    ok.

summarized(ShardId) ->
    macula_rag_contract:shard_summarized(ShardId, ?EMB, [<<"t">>], <<0>>, 1).

published(#{state := State}, Fact) ->
    Topic = macula_rag_contract:topic(?REALM_NAME, <<"acme">>, Fact),
    [{T, P} || {published, T, P} <- ets:tab2list(State), T =:= Topic].

wire(Term) -> macula_record_cbor:decode(macula_record_cbor:encode(Term)).

hex(Node) -> binary:encode_hex(Node, lowercase).
