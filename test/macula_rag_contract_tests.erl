%%% @doc The wire contract every shard of an org speaks: one procedure, two
%%% facts, and the payloads on each, pinned here key for key.
%%%
%%% Payloads are asserted as built and as they read back after macula's CBOR
%%% codec, which hands text back as `{text, Binary}': reading the second form
%%% is what a peer has to do.
-module(macula_rag_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ORG, <<"acme">>).
-define(REALM_NAME, <<"io.macula">>).
-define(EMB, #{model => <<"nomic-embed-text">>, dim => 768}).

%%------------------------------------------------------------------------------
%% Names
%%------------------------------------------------------------------------------

the_procedure_is_the_orgs_test() ->
    ?assertEqual(<<"acme/rag.query_shard_v1">>, macula_rag_contract:procedure(?ORG)),
    %% macula's own parser is the judge of an org namespace.
    ?assertEqual({org, ?ORG}, macula_record:procedure_org(macula_rag_contract:procedure(?ORG))).

an_org_that_would_break_the_namespace_is_refused_test() ->
    [?assertError({invalid_org, Org}, macula_rag_contract:procedure(Org))
     || Org <- [<<>>, <<"a/b">>, <<"_">>, not_binary]].

the_facts_are_canonical_app_facts_test() ->
    ?assertEqual(<<"io.macula/acme/rag/shard/shard_summarized_v1">>,
                 macula_rag_contract:topic(?REALM_NAME, ?ORG, shard_summarized)),
    ?assertEqual(<<"io.macula/acme/rag/shard/shard_withdrawn_v1">>,
                 macula_rag_contract:topic(?REALM_NAME, ?ORG, shard_withdrawn)),
    [?assertMatch({ok, #{tier := app, org := ?ORG, app := <<"rag">>, domain := <<"shard">>, version := 1}},
                  macula_topic:parse(macula_rag_contract:topic(?REALM_NAME, ?ORG, F)))
     || F <- [shard_summarized, shard_withdrawn]].

realm_name_must_hash_to_the_realm_test() ->
    ?assertEqual(ok, macula_rag_contract:check_realm_name(?REALM_NAME, crypto:hash(sha256, ?REALM_NAME))),
    ?assertEqual({error, {realm_name_mismatch, ?REALM_NAME}},
                 macula_rag_contract:check_realm_name(?REALM_NAME, crypto:hash(sha256, <<"x">>))).

%%------------------------------------------------------------------------------
%% Payloads, as built and as read back
%%------------------------------------------------------------------------------

shard_summarized_carries_the_embedding_test() ->
    Built = macula_rag_contract:shard_summarized(<<"s1">>, ?EMB, [<<"a/b">>], <<1, 2>>, 1000),
    ?assertEqual(#{shard_id => <<"s1">>, model => <<"nomic-embed-text">>, dim => 768,
                   topics => [<<"a/b">>], bloom => <<1, 2>>, at_ms => 1000}, Built),
    ?assertEqual({ok, #{shard_id => <<"s1">>, embedding => ?EMB, topics => [<<"a/b">>],
                        bloom => <<1, 2>>, at_ms => 1000}},
                 received(shard_summarized, Built)).

shard_withdrawn_names_the_shard_test() ->
    Built = macula_rag_contract:shard_withdrawn(<<"s1">>, 1000),
    ?assertEqual(#{shard_id => <<"s1">>, at_ms => 1000}, Built),
    ?assertEqual({ok, #{shard_id => <<"s1">>, at_ms => 1000}}, received(shard_withdrawn, Built)).

a_query_names_the_embedding_it_was_made_with_test() ->
    Built = macula_rag_contract:query_shard(#{text => <<"q">>, vector => [0.5, -1.25]}, 3, ?EMB),
    ?assertEqual({ok, #{query => #{<<"text">> => <<"q">>, <<"vector">> => [0.5, -1.25]},
                        top_k => 3, embedding => ?EMB}},
                 received(query_shard, Built)).

an_answer_carries_hits_with_their_minimum_test() ->
    Hits = [#{id => <<"d1">>, score => 0.9, text => <<"x">>}, #{id => <<"d2">>, score => 0.5}],
    Built = macula_rag_contract:shard_answered(<<"s1">>, ?EMB, Hits),
    ?assertEqual({ok, #{shard_id => <<"s1">>, embedding => ?EMB,
                        hits => [#{<<"id">> => <<"d1">>, <<"score">> => 0.9, <<"text">> => <<"x">>},
                                 #{<<"id">> => <<"d2">>, <<"score">> => 0.5}]}},
                 received(shard_answered, Built)).

%% The documented minimum: every hit has a binary `id' and a numeric `score'.
%% A shard that answers with anything less has answered malformed.
a_hit_below_the_minimum_is_malformed_test() ->
    [?assertEqual({error, malformed},
                  received(shard_answered, macula_rag_contract:shard_answered(<<"s1">>, ?EMB, [Bad])))
     || Bad <- [#{id => <<"d">>}, #{score => 1.0}, #{id => 7, score => 1.0}, #{id => <<"d">>, score => <<"high">>}]].

hits_are_checked_before_they_leave_test() ->
    ?assert(macula_rag_contract:valid_hit(#{id => <<"d">>, score => 1})),
    ?assertNot(macula_rag_contract:valid_hit(#{id => <<"d">>})),
    ?assertNot(macula_rag_contract:valid_hit(not_a_map)).

every_payload_is_admissible_and_boolean_free_test() ->
    [begin
         ?assertEqual(ok, macula_frame:check_payload(P)),
         ?assertEqual([], booleans_in(P))
     end || P <- [macula_rag_contract:shard_summarized(<<"s">>, ?EMB, [], <<>>, 1),
                  macula_rag_contract:shard_withdrawn(<<"s">>, 1),
                  macula_rag_contract:query_shard(#{}, 1, ?EMB),
                  macula_rag_contract:shard_answered(<<"s">>, ?EMB, [#{id => <<"d">>, score => 1.0}])]].

malformed_payloads_are_refused_not_crashed_on_test() ->
    [?assertEqual({error, malformed}, macula_rag_contract:parse(K, P))
     || K <- [shard_summarized, shard_withdrawn, query_shard, shard_answered],
        P <- [#{}, not_a_map, #{<<"shard_id">> => 7}]].

%%------------------------------------------------------------------------------

received(Kind, Payload) ->
    macula_rag_contract:parse(Kind, macula_record_cbor:decode(macula_record_cbor:encode(Payload))).

booleans_in(true) -> [true];
booleans_in(false) -> [false];
booleans_in(M) when is_map(M) ->
    lists:append([booleans_in(K) ++ booleans_in(V) || {K, V} <- maps:to_list(M)]);
booleans_in(L) when is_list(L) -> lists:append([booleans_in(E) || E <- L]);
booleans_in(_) -> [].
