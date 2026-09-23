%%% @doc A federated query across shards that each run in their own VM.
%%%
%%% Three `peer' nodes each run the whole library: a configured shard with a
%%% registered responder and a published summary. Two use the querying node's
%%% embedding, one another model. The querying node runs the library too, and
%%% reaches them only as macula would: their summaries arrive at its directory
%%% as facts from their node ids, and a call to a shard runs that shard's own
%%% `macula_rag_responder:handle/1' on its own VM, through macula's codec both
%%% ways. What is faked is the transport, not the shards.
-module(macula_rag_federation_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM_NAME, <<"io.macula">>).
-define(EMB, #{model => <<"nomic">>, dim => 768}).
-define(OTHER, #{model => <<"minilm">>, dim => 384}).
-define(ME, <<16#11:256>>).
-define(ONE, <<16#A1:256>>).
-define(TWO, <<16#A2:256>>).
-define(ELSE, <<16#B1:256>>).

federation_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Ctx) ->
             [{"two shards on two VMs both answer one query, merged by score",
               {timeout, 30, fun() -> both_answer(Ctx) end}},
              {"a shard built with another model is reported, not asked, not merged",
               {timeout, 30, fun() -> other_model_reported(Ctx) end}}]
     end}.

both_answer(_Ctx) ->
    {ok, Hits, #{answered := Answered, failed := Failed}} = macula_rag:query(#{text => <<"q">>},
                                                                             #{top_k => 10}),
    ?assertEqual([<<"one-best">>, <<"two-best">>, <<"one-worst">>], [Id || #{<<"id">> := Id} <- Hits]),
    ?assertEqual(lists:sort([hex(?ONE), hex(?TWO)]), lists:sort(Answered)),
    ?assertMatch([_], Failed),
    ?assertEqual([hex(?ONE), hex(?TWO), hex(?ONE)], [N || #{<<"node_id">> := N} <- Hits]),
    ?assertEqual([<<"shard-one">>, <<"shard-two">>, <<"shard-one">>], [S || #{<<"shard_id">> := S} <- Hits]).

other_model_reported(Ctx) ->
    {ok, _Hits, #{failed := Failed}} = macula_rag:query(#{}, #{top_k => 10}),
    ?assertEqual([{hex(?ELSE), {embedding_mismatch, ?OTHER}}], Failed),
    ?assertEqual(0, calls_to(Ctx, ?ELSE)).

%%------------------------------------------------------------------------------
%% Fixture: three shard VMs and this node
%%------------------------------------------------------------------------------

setup() ->
    Shards = [{?ONE, <<"shard-one">>, ?EMB, [hit(<<"one-best">>, 0.95), hit(<<"one-worst">>, 0.10)]},
              {?TWO, <<"shard-two">>, ?EMB, [hit(<<"two-best">>, 0.50)]},
              {?ELSE, <<"shard-else">>, ?OTHER, [hit(<<"else-best">>, 0.99)]}],
    Peers = maps:from_list([{NodeId, started_shard(NodeId, ShardId, Emb, Hits)}
                            || {NodeId, ShardId, Emb, Hits} <- Shards]),
    Calls = ets:new(federation_calls, [public, bag]),
    stopped(whereis(macula_rag_sup)),
    {ok, Sup} = macula_rag_sup:start_link(),
    unlink(Sup),
    Bus = ets:new(federation_bus, [public, bag]),
    ok = macula_rag:configure(self(), crypto:hash(sha256, ?REALM_NAME),
                              #{org => <<"acme">>, shard_id => <<"querier">>, realm_name => ?REALM_NAME,
                                embedding => ?EMB, query_timeout_ms => 5000,
                                io => io(Peers, Calls, Bus)}),
    [deliver_summaries(NodeId, Peer, Bus) || {NodeId, Peer} <- maps:to_list(Peers)],
    #{peers => Peers, calls => Calls, sup => Sup, bus => Bus}.

cleanup(#{peers := Peers, calls := Calls, sup := Sup, bus := Bus}) ->
    [peer:stop(Peer) || Peer <- maps:values(Peers)],
    stopped(Sup),
    macula_rag:forget_configuration(),
    ets:delete(Calls),
    ets:delete(Bus).

started_shard(NodeId, ShardId, Emb, Hits) ->
    {ok, Peer, _Node} = peer:start_link(#{connection => standard_io,
                                   args => lists:append([["-pa", P] || P <- code:get_path(), in_build(P)])}),
    ok = peer:call(Peer, macula_rag_shard_peer, start, [NodeId, ShardId, Emb, Hits], 15_000),
    Peer.

in_build(Path) -> string:find(Path, "_build") =/= nomatch.

%% The summaries each shard VM published reach this node's directory as facts
%% from that shard's node id, on the subscription made for them.
deliver_summaries(NodeId, Peer, Bus) ->
    Published = peer:call(Peer, macula_rag_shard_peer, published, []),
    [deliver(Bus, Topic, Payload, NodeId) || {Topic, Payload} <- Published],
    _ = sys:get_state(macula_rag_directory),
    ok.

deliver(Bus, Topic, Payload, Publisher) ->
    [Ref | _] = [R || {subscribed, T, R} <- ets:tab2list(Bus), T =:= Topic],
    whereis(macula_rag_directory) ! {macula_event, Ref, Topic, wire(Payload),
                                    #{publisher => Publisher, delivered_via => direct}}.

io(Peers, Calls, Bus) ->
    #{providers => fun(_Pool, _Realm, _Proc, _Timeout) ->
                           {ok, [#{provider => N, station => <<0:256>>} || N <- maps:keys(Peers)]}
                   end,
      call => fun(_Pool, _Realm, _Proc, Payload, _Timeout, #{provider := Node}) ->
                      true = ets:insert(Calls, {called, Node}),
                      remote_answer(peer:call(maps:get(Node, Peers), macula_rag_responder, handle,
                                              [wire(Payload)]))
              end,
      subscribe => fun(_Pool, _Realm, Topic, _Pid) ->
                           Ref = make_ref(),
                           true = ets:insert(Bus, {subscribed, Topic, Ref}),
                           {ok, Ref}
                   end,
      unsubscribe => fun(_Pool, _Ref) -> ok end,
      publish => fun(_Pool, _Realm, _Topic, _Payload) -> ok end,
      provider_authorization => fun(_Pool, _Realm, _Proc) -> {ok, #{}} end,
      advertise => fun(_Pool, _Realm, _Proc, _Handler, _Opts) -> ok end,
      unadvertise => fun(_Pool, _Realm, _Proc) -> ok end,
      self_node_id => fun(_Pool) -> {ok, ?ME} end}.

%% What macula hands a caller: the handler's error as an error, anything else
%% as the reply, through the codec.
remote_answer({error, _} = Refused) -> Refused;
remote_answer(Reply) -> {ok, wire(Reply)}.

calls_to(#{calls := Calls}, Node) -> length([x || {called, N} <- ets:tab2list(Calls), N =:= Node]).

stopped(undefined) -> ok;
stopped(Sup) ->
    Mon = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Mon, process, Sup, _} -> ok after 2000 -> ok end.

hit(Id, Score) -> #{id => Id, score => Score}.

wire(Term) -> macula_record_cbor:decode(macula_record_cbor:encode(Term)).

hex(Node) -> binary:encode_hex(Node, lowercase).
