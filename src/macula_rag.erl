%%% @doc macula_rag public facade.
%%%
%%% Three things you do with this library:
%%%
%%%   1. configure/2 — inject the (Pool, Realm) the library needs to
%%%                    reach the mesh. Call once at boot.
%%%   2. advertise/3 — tell the realm what your shard contains.
%%%   3. register_responder/2 — accept incoming queries.
%%%   4. query/2 — issue a federated query.
%%%
%%% The library does not know what a "vector" is. The wire shape is a
%%% map; the responder callback decides how to interpret it.
%%%
%%% Configuration via persistent_term — all three workers
%%% (advertiser / responder / router) read Pool + Realm from there
%%% on every call. Set once, read many. Re-configure live by calling
%%% configure/2 again.
-module(macula_rag).

-export([
    configure/2,
    pool/0,
    realm/0,
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

-define(PT_POOL,  {?MODULE, pool}).
-define(PT_REALM, {?MODULE, realm}).

%% @doc Set the Macula client pool + realm the library will use.
%% Call once at boot; consumers (hecate-rag, future apps) pass in
%% the same Pool + Realm they use for their other Macula traffic.
%%
%% After this call the responder advertises its RPC method, the
%% router subscribes to the summary channel, and advertisers
%% can actually publish.
-spec configure(pid(), <<_:256>>) -> ok.
configure(Pool, Realm) when is_pid(Pool), is_binary(Realm), byte_size(Realm) =:= 32 ->
    persistent_term:put(?PT_POOL,  Pool),
    persistent_term:put(?PT_REALM, Realm),
    %% Wake the workers so they pick up the new context.
    %% advertise/3 + register_responder/2 + query/2 read pool() / realm()
    %% on every call, so no further action is needed.
    macula_rag_responder:bind(),
    macula_rag_router:bind(),
    ok.

-spec pool() -> {ok, pid()} | {error, not_configured}.
pool() ->
    case persistent_term:get(?PT_POOL, undefined) of
        undefined -> {error, not_configured};
        Pid       -> {ok, Pid}
    end.

-spec realm() -> {ok, <<_:256>>} | {error, not_configured}.
realm() ->
    case persistent_term:get(?PT_REALM, undefined) of
        undefined -> {error, not_configured};
        Bin       -> {ok, Bin}
    end.

%% @doc Announce this shard into the realm via the bloom-advertise
%% channel.
-spec advertise(shard_id(), [binary()], bloom()) -> ok | {error, term()}.
advertise(ShardId, Topics, Bloom) when is_list(Topics), is_binary(Bloom) ->
    macula_rag_advertiser:advertise(ShardId, Topics, Bloom).

-spec withdraw(shard_id()) -> ok.
withdraw(ShardId) ->
    macula_rag_advertiser:withdraw(ShardId).

%% @doc Register a callback that answers incoming queries against
%% the local index.
-spec register_responder(shard_id(), fun((query(), map()) -> {ok, [hit()]} | {error, term()})) ->
    ok | {error, term()}.
register_responder(ShardId, Fun) when is_function(Fun, 2) ->
    macula_rag_responder:register(ShardId, Fun).

-spec unregister_responder(shard_id()) -> ok.
unregister_responder(ShardId) ->
    macula_rag_responder:unregister(ShardId).

%% @doc Fan a query across peers whose summaries indicate they may
%% have relevant content.
-spec query(query()) -> {ok, [hit()]} | {error, term()}.
query(Q) ->
    query(Q, #{}).

-spec query(query(), map()) -> {ok, [hit()]} | {error, term()}.
query(Q, Opts) when is_map(Q), is_map(Opts) ->
    macula_rag_router:query(Q, Opts).
