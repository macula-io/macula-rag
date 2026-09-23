%%% @doc One federated query: who is asked, who answered, who did not and why.
%%%
%%% The mesh is two functions here, `providers' and `call', exactly where
%%% `macula:providers/4' and `macula:call/6' sit; answers still go through
%%% macula's codec, as a real reply does. Nothing a shard fails at is dropped:
%%% every trusted shard is either in `answered' or in `failed' with a reason.
-module(macula_rag_query_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, <<16#AA:256>>).
-define(B, <<16#BB:256>>).
-define(C, <<16#CC:256>>).
-define(ME, <<16#11:256>>).
-define(EMB, #{model => <<"nomic">>, dim => 768}).
-define(OTHER, #{model => <<"minilm">>, dim => 384}).

two_shards_both_answer_and_their_hits_merge_by_score_test() ->
    Ctx = ctx(#{shards => [?A, ?B],
                answers => #{?A => [hit(<<"a1">>, 0.4), hit(<<"a2">>, 0.9)],
                             ?B => [hit(<<"b1">>, 0.7)]}}),
    {ok, Hits, Report} = macula_rag_query:run(#{text => <<"q">>}, #{top_k => 10}, Ctx),
    ?assertEqual([<<"a2">>, <<"b1">>, <<"a1">>], ids(Hits)),
    ?assertEqual(#{answered => lists:sort([hex(?A), hex(?B)]), failed => []}, sorted(Report)),
    %% Every hit says which shard it came from.
    [#{<<"node_id">> := Node, <<"shard_id">> := <<"shard-", _/binary>>} | _] = Hits,
    ?assertEqual(hex(?A), Node).

top_k_bounds_the_merged_hits_test() ->
    Ctx = ctx(#{shards => [?A, ?B],
                answers => #{?A => [hit(<<"a1">>, 0.4), hit(<<"a2">>, 0.9)],
                             ?B => [hit(<<"b1">>, 0.7)]}}),
    {ok, Hits, _} = macula_rag_query:run(#{}, #{top_k => 2}, Ctx),
    ?assertEqual([<<"a2">>, <<"b1">>], ids(Hits)).

%% Scores from two embeddings are not comparable: a shard built with another
%% model is not asked, and says so in `failed'.
a_shard_with_another_embedding_is_reported_not_merged_test() ->
    Ctx = ctx(#{shards => [?A, ?B],
                summaries => #{?B => ?OTHER},
                answers => #{?A => [hit(<<"a1">>, 0.4)], ?B => [hit(<<"b1">>, 0.99)]}}),
    {ok, Hits, Report} = macula_rag_query:run(#{}, #{top_k => 10}, Ctx),
    ?assertEqual([<<"a1">>], ids(Hits)),
    ?assertEqual(#{answered => [hex(?A)], failed => [{hex(?B), {embedding_mismatch, ?OTHER}}]},
                 sorted(Report)),
    ?assertEqual([?A], called(Ctx)).

a_shard_that_answers_with_another_embedding_is_refused_test() ->
    Ctx = ctx(#{shards => [?A], answers => #{?A => {other_embedding, [hit(<<"a1">>, 0.4)]}}}),
    ?assertEqual({ok, [], #{answered => [], failed => [{hex(?A), {embedding_mismatch, ?OTHER}}]}},
                 macula_rag_query:run(#{}, #{top_k => 10}, Ctx)).

a_shard_without_a_summary_is_reported_test() ->
    Ctx = ctx(#{shards => [?A, ?B], summaries => #{?B => none},
                answers => #{?A => [hit(<<"a1">>, 0.4)]}}),
    {ok, _, Report} = macula_rag_query:run(#{}, #{top_k => 10}, Ctx),
    ?assertEqual([{hex(?B), no_summary}], maps:get(failed, Report)),
    ?assertEqual([?A], called(Ctx)).

a_failed_call_is_reported_with_its_reason_test() ->
    Ctx = ctx(#{shards => [?A, ?B],
                answers => #{?A => [hit(<<"a1">>, 0.4)], ?B => {error, {unresolved, timeout}}}}),
    {ok, Hits, Report} = macula_rag_query:run(#{}, #{top_k => 10}, Ctx),
    ?assertEqual([<<"a1">>], ids(Hits)),
    ?assertEqual([{hex(?B), {unresolved, timeout}}], maps:get(failed, Report)).

a_malformed_answer_is_reported_test() ->
    Ctx = ctx(#{shards => [?A], answers => #{?A => {raw, #{nonsense => 1}}}}),
    ?assertEqual({ok, [], #{answered => [], failed => [{hex(?A), malformed_answer}]}},
                 macula_rag_query:run(#{}, #{top_k => 10}, Ctx)).

%% A shard slower than the query's timeout is reported as timed out, and the
%% answer comes back within the timeout, not after the slowest shard.
a_slow_shard_times_out_without_holding_the_query_test() ->
    Ctx = ctx(#{shards => [?A, ?B],
                answers => #{?A => [hit(<<"a1">>, 0.4)], ?B => {sleep, 2000}}}),
    T0 = erlang:monotonic_time(millisecond),
    {ok, Hits, Report} = macula_rag_query:run(#{}, #{top_k => 10, timeout_ms => 300}, Ctx),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1500),
    ?assertEqual([<<"a1">>], ids(Hits)),
    ?assertEqual([{hex(?B), timeout}], maps:get(failed, Report)).

%% The query runs in the caller's process: a shard it gave up on must leave
%% nothing behind in that process's mailbox.
a_timed_out_shard_leaves_no_message_behind_test() ->
    Ctx = ctx(#{shards => [?A], answers => #{?A => {sleep, 2000}}}),
    {ok, [], _} = macula_rag_query:run(#{}, #{top_k => 10, timeout_ms => 100}, Ctx),
    timer:sleep(200),
    ?assertEqual({messages, []}, process_info(self(), messages)).

%% This node is a shard too: it answers in-process, through the same codec a
%% peer's answer goes through, and is never dialled.
this_nodes_own_shard_answers_locally_test() ->
    Ctx = ctx(#{shards => [?ME, ?A],
                answers => #{?A => [hit(<<"a1">>, 0.4)], ?ME => [hit(<<"m1">>, 0.8)]}}),
    {ok, Hits, Report} = macula_rag_query:run(#{}, #{top_k => 10}, Ctx),
    ?assertEqual([<<"m1">>, <<"a1">>], ids(Hits)),
    ?assertEqual(lists:sort([hex(?ME), hex(?A)]), lists:sort(maps:get(answered, Report))),
    ?assertEqual([?A], called(Ctx)).

%% A provider that serves through two stations is listed twice; it is one
%% shard and is asked once.
a_provider_listed_twice_is_asked_once_test() ->
    Ctx = ctx(#{shards => [?A, ?A], answers => #{?A => [hit(<<"a1">>, 0.4)]}}),
    {ok, Hits, _} = macula_rag_query:run(#{}, #{top_k => 10}, Ctx),
    ?assertEqual([<<"a1">>], ids(Hits)),
    ?assertEqual([?A], called(Ctx)).

no_shard_at_all_is_an_error_naming_why_test() ->
    Ctx = ctx(#{providers => {error, {unresolved, procedure_not_advertised}}}),
    ?assertEqual({error, {no_shards, {unresolved, procedure_not_advertised}}},
                 macula_rag_query:run(#{}, #{top_k => 10}, Ctx)).

%%------------------------------------------------------------------------------
%% The fake mesh
%%------------------------------------------------------------------------------

%% `shards' are the providers macula lists; each has a summary with ?EMB unless
%% `summaries' says otherwise (`none' for no summary). `answers' is what each
%% shard's responder answers with.
ctx(Spec) ->
    Calls = ets:new(calls, [public, bag]),
    Shards = maps:get(shards, Spec, []),
    Summaries = maps:merge(maps:from_list([{S, ?EMB} || S <- Shards]), maps:get(summaries, Spec, #{})),
    Answers = maps:get(answers, Spec, #{}),
    Answer = fun(Node) -> answer(maps:get(Node, Answers, []), Node) end,
    #{embedding => ?EMB,
      self => ?ME,
      timeout_ms => 1000,
      calls => Calls,
      providers => fun() -> provided(maps:get(providers, Spec, {ok, Shards})) end,
      summary => fun(Node) -> summary(maps:get(Node, Summaries, none), Node) end,
      call => fun(Node, Payload) ->
                      true = ets:insert(Calls, {called, Node}),
                      {ok, _} = macula_rag_contract:parse(query_shard, wire(Payload)),
                      Answer(Node)
              end,
      local => fun(Payload) ->
                       {ok, _} = macula_rag_contract:parse(query_shard, wire(Payload)),
                       Answer(?ME)
               end}.

provided({ok, Nodes}) -> {ok, [#{provider => N, station => <<0:256>>} || N <- Nodes]};
provided(Error) -> Error.

summary(none, _Node) -> none;
summary(Emb, Node) -> {ok, #{shard_id => shard_id(Node), embedding => Emb}}.

answer({error, _} = E, _Node) -> E;
answer({raw, Reply}, _Node) -> {ok, wire(Reply)};
answer({sleep, Ms}, Node) -> timer:sleep(Ms), answer([], Node);
answer({other_embedding, Hits}, Node) ->
    {ok, wire(macula_rag_contract:shard_answered(shard_id(Node), ?OTHER, Hits))};
answer(Hits, Node) ->
    {ok, wire(macula_rag_contract:shard_answered(shard_id(Node), ?EMB, Hits))}.

wire(Term) -> macula_record_cbor:decode(macula_record_cbor:encode(Term)).

called(#{calls := Calls}) -> lists:sort([N || {called, N} <- ets:tab2list(Calls)]).

hit(Id, Score) -> #{id => Id, score => Score}.

ids(Hits) -> [Id || #{<<"id">> := Id} <- Hits].

shard_id(Node) -> <<"shard-", (binary:part(hex(Node), 0, 4))/binary>>.

hex(Node) -> binary:encode_hex(Node, lowercase).

sorted(#{answered := A, failed := F}) -> #{answered => lists:sort(A), failed => lists:sort(F)}.
