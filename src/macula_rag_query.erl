%%% @doc One federated query: ask every shard of the org whose embedding
%%% matches, in parallel, and merge the answers by score.
%%%
%%% The shards are the providers macula lists for the org's procedure, which it
%%% has already checked against the org's D25 delegations; a provider listed
%%% through two stations is one shard. Each is then judged by the summary it
%%% published:
%%%
%%%   no summary          not asked, `no_summary'
%%%   another embedding   not asked, `{embedding_mismatch, Theirs}'
%%%   same embedding      asked, and its answer is judged again: an answer in
%%%                       another embedding, or one below the contract, is
%%%                       refused rather than merged
%%%
%%% NOTHING IS DROPPED SILENTLY. Every shard ends in `answered' or in `failed'
%%% with its reason, node ids in lowercase hex. A shard slower than the timeout
%%% is `timeout' and does not hold up the others.
%%%
%%% The mesh arrives as functions in `Ctx' (`providers', `summary', `call',
%%% `local'), so the fan-out is tested without one. This node's own shard, when
%%% it is one, answers through `local' and is never dialled.
-module(macula_rag_query).

-export([run/3]).

-define(DEFAULT_TOP_K, 10).

-type report() :: #{answered := [binary()], failed := [{binary(), term()}]}.

-export_type([report/0]).

%% @doc Run `Query' across the org's shards.
-spec run(map(), map(), map()) -> {ok, [map()], report()} | {error, {no_shards, term()}}.
run(Query, Opts, #{providers := Providers} = Ctx) ->
    listed(Providers(), Query, Opts, Ctx).

listed({error, Reason}, _Query, _Opts, _Ctx) ->
    {error, {no_shards, Reason}};
listed({ok, Listed}, Query, Opts, #{embedding := Emb, timeout_ms := DefaultTimeout} = Ctx) ->
    TopK = maps:get(top_k, Opts, ?DEFAULT_TOP_K),
    Timeout = maps:get(timeout_ms, Opts, DefaultTimeout),
    Payload = macula_rag_contract:query_shard(Query, TopK, Emb),
    Judged = [{Node, askable(summary_of(Node, Ctx), Emb)}
              || Node <- lists:usort([P || #{provider := P} <- Listed])],
    Asked = fan_out([{Node, Summary} || {Node, {ask, Summary}} <- Judged], Payload, Timeout, Ctx),
    Refused = [{Node, Why} || {Node, {refuse, Why}} <- Judged],
    merged(TopK, [answer(Node, Result, Emb) || {Node, Result} <- Asked] ++
                 [{failed, Node, Why} || {Node, Why} <- Refused]).

summary_of(Node, #{summary := Summary}) -> Summary(Node).

askable(none, _Emb) -> {refuse, no_summary};
askable({ok, #{embedding := Emb} = Summary}, Emb) -> {ask, Summary};
askable({ok, #{embedding := Theirs}}, _Emb) -> {refuse, {embedding_mismatch, Theirs}}.

%%------------------------------------------------------------------------------
%% Asking, in parallel, within the timeout
%%------------------------------------------------------------------------------

fan_out(Shards, Payload, Timeout, Ctx) ->
    Parent = self(),
    Workers = maps:from_list([{worker(Parent, Node, Payload, Ctx), Node} || {Node, _Summary} <- Shards]),
    collect(Workers, erlang:monotonic_time(millisecond) + Timeout, []).

worker(Parent, Node, Payload, Ctx) ->
    {Pid, Mon} = spawn_monitor(fun() -> Parent ! {shard_result, self(), asked(Node, Payload, Ctx)} end),
    {Pid, Mon}.

asked(Node, Payload, #{self := Node, local := Local}) ->
    Local(Payload);
asked(Node, Payload, #{call := Call}) ->
    Call(Node, Payload).

collect(Workers, _Deadline, Acc) when map_size(Workers) =:= 0 ->
    Acc;
collect(Workers, Deadline, Acc) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {shard_result, Pid, Result} ->
            {Key, Node} = worker_of(Pid, Workers),
            {_, Mon} = Key,
            erlang:demonitor(Mon, [flush]),
            collect(maps:remove(Key, Workers), Deadline, [{Node, Result} | Acc]);
        {'DOWN', Mon, process, Pid, Reason} when is_map_key({Pid, Mon}, Workers) ->
            collect(maps:remove({Pid, Mon}, Workers), Deadline,
                    [{maps:get({Pid, Mon}, Workers), {error, {crashed, Reason}}} | Acc])
    after Left ->
        [gave_up(Key, Node) || {Key, Node} <- maps:to_list(Workers)] ++ Acc
    end.

%% A shard given up on is stopped, and its monitor and any answer already on
%% its way are dropped, so the caller's mailbox keeps nothing of it.
gave_up({Pid, Mon}, Node) ->
    erlang:demonitor(Mon, [flush]),
    exit(Pid, kill),
    receive {shard_result, Pid, _Late} -> ok after 0 -> ok end,
    {Node, timeout}.

worker_of(Pid, Workers) ->
    hd([{Key, Node} || {{P, _} = Key, Node} <- maps:to_list(Workers), P =:= Pid]).

%%------------------------------------------------------------------------------
%% Judging the answers, and merging them
%%------------------------------------------------------------------------------

answer(Node, timeout, _Emb) ->
    {failed, Node, timeout};
answer(Node, {error, Reason}, _Emb) ->
    {failed, Node, Reason};
answer(Node, {ok, Reply}, Emb) ->
    judged(Node, macula_rag_contract:parse(shard_answered, Reply), Emb).

judged(Node, {ok, #{embedding := Emb, shard_id := ShardId, hits := Hits}}, Emb) ->
    NodeId = hex(Node),
    {answered, Node, [Hit#{<<"shard_id">> => ShardId, <<"node_id">> => NodeId} || Hit <- Hits]};
judged(Node, {ok, #{embedding := Theirs}}, _Emb) ->
    {failed, Node, {embedding_mismatch, Theirs}};
judged(Node, {error, malformed}, _Emb) ->
    {failed, Node, malformed_answer}.

merged(TopK, Outcomes) ->
    Hits = lists:append([H || {answered, _Node, H} <- Outcomes]),
    Ranked = lists:sort(fun(A, B) -> score(A) >= score(B) end, Hits),
    {ok, lists:sublist(Ranked, TopK),
     #{answered => [hex(Node) || {answered, Node, _} <- Outcomes],
       failed => [{hex(Node), Why} || {failed, Node, Why} <- Outcomes]}}.

score(#{<<"score">> := Score}) -> Score.

hex(Node) -> binary:encode_hex(Node, lowercase).
