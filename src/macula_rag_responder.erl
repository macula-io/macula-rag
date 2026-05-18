%%% @doc Handles incoming federated queries.
%%%
%%% At configure/2 time, advertises the RPC method
%%% `<<"macula-rag.query">>' against the configured pool + realm.
%%% Inbound calls invoke `dispatch/1` (this module, exported MFA
%%% form) which dispatches into every registered responder callback,
%%% merges + ranks hits, returns the response.
-module(macula_rag_responder).
-behaviour(gen_server).

-export([start_link/0, register/2, unregister/1, bind/0, dispatch/1, rpc_method/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    callbacks = #{} :: #{macula_rag:shard_id() => fun()},
    advertised = false :: boolean()
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(ShardId, Fun) when is_function(Fun, 2) ->
    gen_server:call(?MODULE, {register, ShardId, Fun}).

unregister(ShardId) ->
    gen_server:call(?MODULE, {unregister, ShardId}).

%% @doc Called by macula_rag:configure/2 to (re-)advertise the RPC
%% method against the current pool + realm.
-spec bind() -> ok | {error, term()}.
bind() ->
    gen_server:call(?MODULE, bind).

-spec rpc_method() -> binary().
rpc_method() ->
    application:get_env(macula_rag, rpc_method, <<"macula-rag.query">>).

%% @doc Dispatch entry point — registered with the SDK as
%% `{?MODULE, dispatch}` so the Macula client calls it when an
%% inbound RPC arrives.
-spec dispatch(map()) -> map() | {error, term()}.
dispatch(QueryMsg) ->
    gen_server:call(?MODULE, {rpc, QueryMsg}).

%%% gen_server

init([]) ->
    {ok, #state{}}.

handle_call({register, ShardId, Fun}, _From, #state{callbacks = M} = S) ->
    {reply, ok, S#state{callbacks = M#{ShardId => Fun}}};
handle_call({unregister, ShardId}, _From, #state{callbacks = M} = S) ->
    {reply, ok, S#state{callbacks = maps:remove(ShardId, M)}};
handle_call(bind, _From, S) ->
    case advertise_method() of
        ok           -> {reply, ok, S#state{advertised = true}};
        {error, _} = E -> {reply, E, S}
    end;
handle_call({rpc, QueryMsg}, _From, #state{callbacks = M} = S) ->
    Reply = answer(QueryMsg, M),
    {reply, Reply, S};
handle_call(_, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _)   -> ok.

%%% Internals

advertise_method() ->
    case {macula_rag:pool(), macula_rag:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            try
                ok = macula:advertise(Pool, Realm, rpc_method(),
                                      {?MODULE, dispatch}, #{}),
                ok
            catch C:R -> {error, {advertise_failed, C, R}}
            end;
        _ ->
            {error, not_configured}
    end.

answer(#{type := query, query := Q, top_k := TopK, query_id := QId}, Callbacks) ->
    Hits = lists:foldl(
        fun(Fun, Acc) ->
            case Fun(Q, #{top_k => TopK}) of
                {ok, Items} -> Items ++ Acc;
                _Err        -> Acc
            end
        end,
        [],
        maps:values(Callbacks)
    ),
    macula_rag_protocol:new_response(QId, lists:sublist(rank(Hits), TopK));
answer(_, _) ->
    {error, bad_query}.

%% @doc Stable rank by score descending. Hits without `score` go last.
rank(Hits) ->
    lists:sort(
        fun(A, B) ->
            maps:get(score, A, 0.0) >= maps:get(score, B, 0.0)
        end,
        Hits
    ).
