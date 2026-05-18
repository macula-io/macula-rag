%%% @doc Outbound side: fans a query across peers whose advertised
%%% summary suggests they might have relevant content.
%%%
%%% Picks N peers based on Bloom-match against the query topics,
%%% issues Macula RPCs in parallel, merges + ranks the responses.
-module(macula_rag_router).
-behaviour(gen_server).

-export([start_link/0, query/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    peer_summaries = #{} :: #{binary() => macula_rag_protocol:summary_msg()}
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec query(map(), map()) -> {ok, [map()]} | {error, term()}.
query(Q, Opts) ->
    TopK    = maps:get(top_k, Opts, 10),
    Timeout = maps:get(timeout_ms, Opts, default_timeout()),
    QueryMsg = macula_rag_protocol:new_query(Q, TopK),
    gen_server:call(?MODULE, {query, QueryMsg, Timeout, TopK}, Timeout + 500).

%%% gen_server

init([]) ->
    %% TODO: subscribe to the bloom-advertise topic to maintain
    %% peer_summaries map.
    {ok, #state{}}.

handle_call({query, QMsg, Timeout, TopK}, _From, #state{peer_summaries = Peers} = S) ->
    Candidates = select_peers(QMsg, Peers),
    Hits = fan_query(QMsg, Candidates, Timeout),
    Ranked = lists:sublist(rank(Hits), TopK),
    {reply, {ok, Ranked}, S};
handle_call({peer_summary, Summary}, _From, #state{peer_summaries = Peers} = S) ->
    NewPeers = Peers#{maps:get(shard_id, Summary) => Summary},
    {reply, ok, S#state{peer_summaries = NewPeers}};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _)   -> ok.

%%% Internals

select_peers(_QueryMsg, Peers) ->
    %% TODO: Bloom-match QueryMsg.query against each peer's bloom; rank
    %% by hit-count, return top N. For the scaffold, return all peers.
    maps:keys(Peers).

fan_query(_QMsg, [], _Timeout) ->
    [];
fan_query(QMsg, ShardIds, Timeout) ->
    Self = self(),
    Ref  = make_ref(),
    Pids = [spawn_link(fun() -> Self ! {Ref, rpc(SId, QMsg)} end) || SId <- ShardIds],
    collect(Ref, length(Pids), Timeout, []).

rpc(_ShardId, _QMsg) ->
    %% TODO: macula:call(Client, ShardId, ?RPC_METHOD, QMsg, Timeout)
    {error, not_wired}.

collect(_Ref, 0, _Timeout, Acc) ->
    lists:flatten(Acc);
collect(Ref, N, Timeout, Acc) ->
    receive
        {Ref, {ok, Resp}} ->
            Hits = maps:get(hits, Resp, []),
            collect(Ref, N - 1, Timeout, [Hits | Acc]);
        {Ref, _Other} ->
            collect(Ref, N - 1, Timeout, Acc)
    after Timeout ->
        lists:flatten(Acc)
    end.

rank(Hits) ->
    lists:sort(
        fun(A, B) ->
            maps:get(score, A, 0.0) >= maps:get(score, B, 0.0)
        end,
        Hits
    ).

default_timeout() ->
    application:get_env(macula_rag, default_query_timeout_ms, 1500).
