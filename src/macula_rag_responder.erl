%%% @doc Handles incoming federated queries by delegating to a
%%% user-supplied callback (typically `hecate_app_rag`'s
%%% `serve_retrieval:answer_query/2`).
-module(macula_rag_responder).
-behaviour(gen_server).

-export([start_link/0, register/2, unregister/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    callbacks = #{} :: #{macula_rag:shard_id() => fun()}
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register(ShardId, Fun) when is_function(Fun, 2) ->
    gen_server:call(?MODULE, {register, ShardId, Fun}).

unregister(ShardId) ->
    gen_server:call(?MODULE, {unregister, ShardId}).

%%% gen_server

init([]) ->
    %% TODO: macula:advertise(Client, ?RPC_METHOD, ?MODULE)
    %% so incoming RPCs surface here.
    {ok, #state{}}.

handle_call({register, ShardId, Fun}, _From, #state{callbacks = M} = S) ->
    {reply, ok, S#state{callbacks = M#{ShardId => Fun}}};
handle_call({unregister, ShardId}, _From, #state{callbacks = M} = S) ->
    {reply, ok, S#state{callbacks = maps:remove(ShardId, M)}};
handle_call({rpc, QueryMsg}, _From, #state{callbacks = M} = S) ->
    Reply = answer(QueryMsg, M),
    {reply, Reply, S};
handle_call(_, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _)   -> ok.

%%% Internals

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
