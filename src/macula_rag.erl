%%% @doc macula_rag public facade.
%%%
%%% Three things you do with this library:
%%%
%%%   1. advertise/3 — tell the realm what your shard contains
%%%   2. register_responder/2 — accept incoming queries
%%%   3. query/2 — issue a federated query
%%%
%%% The library does not know what a "vector" is. The wire shape is a
%%% map; the responder callback decides how to interpret it.
-module(macula_rag).

-export([
    advertise/3,
    withdraw/1,
    register_responder/2,
    unregister_responder/1,
    query/1,
    query/2
]).

-export_type([
    shard_id/0,
    query/0,
    hit/0,
    bloom/0
]).

-type shard_id() :: atom() | binary().
-type query()    :: map().
-type hit()      :: map().
-type bloom()    :: binary().

%% @doc Announce this shard into the realm via the bloom-advertise
%% channel. `Topics` is a list of binary "namespaces" the shard covers
%% (e.g. <<"hecate-agents/philosophy">>); `Bloom` is an opaque
%% summary of the indexed content (typically a bloom filter over chunk
%% headings / source paths).
-spec advertise(shard_id(), [binary()], bloom()) -> ok | {error, term()}.
advertise(ShardId, Topics, Bloom) when is_list(Topics), is_binary(Bloom) ->
    macula_rag_advertiser:advertise(ShardId, Topics, Bloom).

-spec withdraw(shard_id()) -> ok.
withdraw(ShardId) ->
    macula_rag_advertiser:withdraw(ShardId).

%% @doc Register a callback that answers incoming queries against the
%% local index. Called from the responder process; must be fast or
%% spawn its own worker.
-spec register_responder(shard_id(), fun((query(), map()) -> {ok, [hit()]} | {error, term()})) ->
    ok | {error, term()}.
register_responder(ShardId, Fun) when is_function(Fun, 2) ->
    macula_rag_responder:register(ShardId, Fun).

-spec unregister_responder(shard_id()) -> ok.
unregister_responder(ShardId) ->
    macula_rag_responder:unregister(ShardId).

%% @doc Fan a query across peers whose summaries indicate they may
%% have relevant content. Merge + rank results, return top-k.
-spec query(query()) -> {ok, [hit()]} | {error, term()}.
query(Q) ->
    query(Q, #{}).

-spec query(query(), map()) -> {ok, [hit()]} | {error, term()}.
query(Q, Opts) when is_map(Q), is_map(Opts) ->
    macula_rag_router:query(Q, Opts).
