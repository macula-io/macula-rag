%%% @doc One shard running the whole library in its own VM, for the federation
%%% test. Runs on a `peer' node: it starts macula_rag, configures it, registers
%%% a responder that answers with fixed hits, and advertises its summary. What
%%% it publishes is kept in a table the test node reads back, because a peer
%%% started over standard_io has no distribution to message the test node with.
-module(macula_rag_shard_peer).

-export([start/4, published/0]).

-define(REALM_NAME, <<"io.macula">>).

%% @doc Start the shard `NodeId' with `Embedding', answering every query with
%% `Hits'. Returns once its summary is published.
start(NodeId, ShardId, Embedding, Hits) ->
    Test = self(),
    _ = spawn(fun() -> run(Test, NodeId, ShardId, Embedding, Hits) end),
    receive {shard_started, Result} -> Result after 10_000 -> {error, shard_did_not_start} end.

%% @doc What this shard published, as `{Topic, Payload}'.
published() ->
    [{T, P} || {published, T, P} <- ets:tab2list(macula_rag_shard_peer_published)].

run(Test, NodeId, ShardId, Embedding, Hits) ->
    macula_rag_shard_peer_published = ets:new(macula_rag_shard_peer_published, [named_table, public, bag]),
    {ok, _Sup} = macula_rag_sup:start_link(),
    ok = macula_rag:configure(self(), crypto:hash(sha256, ?REALM_NAME),
                              #{org => <<"acme">>, shard_id => ShardId, realm_name => ?REALM_NAME,
                                embedding => Embedding, io => io(NodeId)}),
    ok = macula_rag:register_responder(fun(_Query, #{top_k := K}) -> {ok, lists:sublist(Hits, K)} end),
    ok = macula_rag:advertise([<<"topic">>], <<0>>),
    Test ! {shard_started, ok},
    receive stop -> ok end.

io(NodeId) ->
    #{provider_authorization => fun(_Pool, _Realm, _Proc) -> {ok, #{}} end,
      advertise => fun(_Pool, _Realm, _Proc, _Handler, _Opts) -> ok end,
      unadvertise => fun(_Pool, _Realm, _Proc) -> ok end,
      subscribe => fun(_Pool, _Realm, _Topic, _Pid) -> {ok, make_ref()} end,
      unsubscribe => fun(_Pool, _Ref) -> ok end,
      publish => fun(_Pool, _Realm, Topic, Payload) ->
                         true = ets:insert(macula_rag_shard_peer_published, {published, Topic, Payload}),
                         ok
                 end,
      self_node_id => fun(_Pool) -> {ok, NodeId} end}.
