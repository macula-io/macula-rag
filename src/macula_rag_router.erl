%%% @doc Outbound side: fans a query across peers whose advertised
%%% summary suggests they might have relevant content.
%%%
%%% Maintains a `peer_summaries' map by subscribing to the summary
%%% topic published by every macula_rag_advertiser in the realm.
%%% On query/2, picks N peers (today: all of them), issues unary
%%% RPCs against `<<"macula-rag.query">>' in parallel, merges + ranks
%%% the partial responses.
-module(macula_rag_router).
-behaviour(gen_server).

-export([start_link/0, query/2, bind/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    peer_summaries = #{}    :: #{binary() => macula_rag_protocol:summary_msg()},
    summary_sub    = undefined :: reference() | undefined
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

%% @doc Called by macula_rag:configure/2 — (re-)subscribes the
%% router to the summary topic so it can build its peer set.
-spec bind() -> ok | {error, term()}.
bind() ->
    gen_server:call(?MODULE, bind).

%%% gen_server

init([]) ->
    {ok, #state{}}.

handle_call(bind, _From, #state{summary_sub = OldRef} = S) ->
    %% Tear down any previous subscription (reconfigure case)
    case OldRef of
        undefined -> ok;
        _         -> safe_unsubscribe(OldRef)
    end,
    case subscribe_summaries() of
        {ok, Ref}      -> {reply, ok, S#state{summary_sub = Ref}};
        {error, _} = E -> {reply, E, S#state{summary_sub = undefined}}
    end;

handle_call({query, QMsg, Timeout, TopK}, _From, #state{peer_summaries = Peers} = S) ->
    Candidates = select_peers(QMsg, Peers),
    Hits = fan_query(QMsg, Candidates, Timeout),
    Ranked = lists:sublist(rank(Hits), TopK),
    {reply, {ok, Ranked}, S};

handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.

%% Macula delivers subscription messages as {macula_event, SubRef, Topic, Payload}.
handle_info({macula_event, _Ref, _Topic, #{type := summary} = Summary},
            #state{peer_summaries = Peers} = S) ->
    NewPeers = Peers#{maps:get(shard_id, Summary) => Summary},
    {noreply, S#state{peer_summaries = NewPeers}};
handle_info({macula_event, _Ref, _Topic, #{type := summary_withdrawn, shard_id := SId}},
            #state{peer_summaries = Peers} = S) ->
    {noreply, S#state{peer_summaries = maps:remove(SId, Peers)}};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internals

subscribe_summaries() ->
    case {macula_rag:pool(), macula_rag:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            try macula:subscribe(Pool, Realm,
                                 macula_rag_advertiser:summary_topic(),
                                 self())
            catch C:R -> {error, {subscribe_failed, C, R}}
            end;
        _ ->
            {error, not_configured}
    end.

safe_unsubscribe(Ref) ->
    case macula_rag:pool() of
        {ok, Pool} ->
            try macula:unsubscribe(Pool, Ref)
            catch _:_ -> ok
            end;
        _ ->
            ok
    end.

select_peers(_QueryMsg, Peers) ->
    %% TODO: Bloom-match QueryMsg.query against each peer's bloom; rank
    %% by hit-count, return top N. For now, return every known peer.
    maps:keys(Peers).

fan_query(_QMsg, [], _Timeout) ->
    [];
fan_query(QMsg, ShardIds, Timeout) ->
    Self = self(),
    Ref  = make_ref(),
    _Pids = [spawn_link(fun() -> Self ! {Ref, rpc(SId, QMsg, Timeout)} end)
             || SId <- ShardIds],
    collect(Ref, length(ShardIds), Timeout, []).

rpc(_ShardId, QMsg, Timeout) ->
    case {macula_rag:pool(), macula_rag:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            Method = macula_rag_responder:rpc_method(),
            try macula:call(Pool, Realm, Method, QMsg, Timeout)
            catch C:R -> {error, {call_failed, C, R}}
            end;
        _ ->
            {error, not_configured}
    end.

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
