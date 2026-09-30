%% @doc The RAG service contract's corpus identity, against the frozen vectors
%% in test/vectors (guides/rag_service_contract.md carries the same ones).
%%
%% corpus_hash is the sha256 of the RFC 8785 canonical JSON of the described
%% model, dim and repos. A provider may sign it; a caller counts a corpus as
%% signed by P only when it pinned P, the object verifies under the label, the
%% node id derived from the verified key is P, and the signed hash is the one
%% it recomputed. verify/3 is that check, and nothing else counts: signed_by is
%% a display label.
-module(macula_rag_corpus_tests).

-include_lib("eunit/include/eunit.hrl").

%%------------------------------------------------------------------------------
%% The vectors
%%------------------------------------------------------------------------------

canonical_json_vectors_test() ->
    [?assertEqual(Canonical, macula_rag_corpus:canonical_json(Input))
     || #{<<"input">> := Input, <<"canonical">> := Canonical} <- maps:get(<<"jcs">>, vectors())].

corpus_hash_vectors_test() ->
    [?assertEqual(Hash, macula_rag_corpus:corpus_hash(Description))
     || #{<<"description">> := Description, <<"corpus_hash">> := Hash} <- maps:get(<<"corpus_hash">>, vectors())].

the_label_is_the_vector_test() ->
    #{<<"label">> := Label, <<"label_hex">> := Hex} = vectors(),
    ?assertEqual(Label, macula_rag_corpus:signature_label()),
    ?assertEqual(binary:decode_hex(Hex), macula_rag_corpus:signature_label()).

a_signed_vector_verifies_as_signed_by_its_node_test() ->
    [?assertEqual({ok, {signed, binary:decode_hex(SignedBy)}},
                  macula_rag_corpus:verify(described(V), binary:decode_hex(SignedBy), profile(V)))
     || #{<<"signed_by">> := SignedBy} = V <- signed_vectors()].

%%------------------------------------------------------------------------------
%% What a caller must not be fooled by
%%------------------------------------------------------------------------------

%% Provider B serves A's description and signature: B is who the caller
%% pinned, so the signer is not the provider.
a_copied_signature_is_not_the_providers_test() ->
    [V | _] = signed_vectors(),
    Other = binary:copy(<<16#42>>, 32),
    ?assertEqual({error, signer_not_provider}, macula_rag_corpus:verify(described(V), Other, profile(V))).

%% signed_by is never evidence: naming the pinned provider there changes nothing.
signed_by_is_not_evidence_test() ->
    [V | _] = signed_vectors(),
    Other = binary:copy(<<16#42>>, 32),
    Lying = (described(V))#{signed_by => binary:encode_hex(Other, lowercase)},
    ?assertEqual({error, signer_not_provider}, macula_rag_corpus:verify(Lying, Other, profile(V))).

%% A description whose repos were changed no longer hashes to what it claims.
a_changed_repo_list_is_refused_test() ->
    [V | _] = signed_vectors(),
    #{repos := [R | Rest]} = D = described(V),
    Changed = D#{repos => [R#{commit => binary:copy(<<"f">>, 40)} | Rest]},
    ?assertEqual({error, corpus_hash_mismatch}, macula_rag_corpus:verify(Changed, signer(V), profile(V))).

%% ...and one whose claimed hash was changed to match is not what was signed.
a_rehashed_description_is_not_what_was_signed_test() ->
    [V | _] = signed_vectors(),
    #{repos := [R | Rest]} = D = described(V),
    Changed = D#{repos => [R#{commit => binary:copy(<<"f">>, 40)} | Rest]},
    Rehashed = Changed#{corpus_hash => macula_rag_corpus:corpus_hash(Changed)},
    ?assertEqual({error, signature_hash_mismatch},
                 macula_rag_corpus:verify(Rehashed, signer(V), profile(V))).

%% A signature for the other profile, or garbage, is refused with macula's reason.
a_signature_that_does_not_verify_is_refused_test() ->
    [Pure, Hybrid] = signed_vectors(),
    ?assertMatch({error, {signature, _}},
                 macula_rag_corpus:verify(described(Pure), signer(Pure), pq_hybrid)),
    ?assertMatch({error, {signature, _}},
                 macula_rag_corpus:verify((described(Hybrid))#{signature => <<"not cbor">>},
                                          signer(Hybrid), pq_hybrid)).

%% No signature: an unsigned corpus, whose hash still has to hold.
an_unsigned_corpus_test() ->
    [V | _] = signed_vectors(),
    Unsigned = maps:without([signature, signed_by], described(V)),
    ?assertEqual({ok, unsigned}, macula_rag_corpus:verify(Unsigned, signer(V), profile(V))),
    ?assertEqual({error, corpus_hash_mismatch},
                 macula_rag_corpus:verify(Unsigned#{dim => 768}, signer(V), profile(V))).

%% As a caller receives it from macula: text values tagged, keys atoms or
%% binaries, the signature a byte string.
the_received_shape_verifies_test() ->
    [V | _] = signed_vectors(),
    #{repos := Repos} = D = described(V),
    Received = #{<<"corpus_hash">> => {text, maps:get(corpus_hash, D)},
                 model => {text, maps:get(model, D)}, dim => maps:get(dim, D),
                 repos => [maps:map(fun(_K, Val) -> {text, Val} end, R) || R <- Repos],
                 signature => maps:get(signature, D)},
    ?assertEqual({ok, {signed, signer(V)}}, macula_rag_corpus:verify(Received, signer(V), profile(V))).

%%------------------------------------------------------------------------------
%% Signing, as a provider does it
%%------------------------------------------------------------------------------

sign_round_trip_test_() ->
    {setup, fun() -> {ok, K} = macula_node_keys:generate(identity, pq_pure), K end,
     fun(Key) ->
         fun() ->
             [#{<<"description">> := Plain, <<"corpus_hash">> := Hash}] = maps:get(<<"corpus_hash">>, vectors()),
             {ok, NodeId} = macula_node_keys:node_id(Key),
             D = (atomized(Plain))#{corpus_hash => Hash, signature => macula_rag_corpus:sign(Hash, Key)},
             ?assertEqual({ok, {signed, NodeId}}, macula_rag_corpus:verify(D, NodeId, pq_pure))
         end
     end}.

%%------------------------------------------------------------------------------
%% A hit's provenance
%%------------------------------------------------------------------------------

a_hit_whose_text_is_its_hash_test() ->
    ?assertEqual(ok, macula_rag_corpus:verify_hit(hit(<<"pangolins roll up">>))).

a_hit_whose_text_changed_is_refused_test() ->
    Hit = (hit(<<"pangolins roll up">>))#{content => <<"pangolins fly">>},
    ?assertEqual({error, content_mismatch}, macula_rag_corpus:verify_hit(Hit)).

%% Corpus content names its repo and a 40-hex commit; a deposit names neither.
provenance_shape_test() ->
    #{provenance := Corpus} = hit(<<"x">>),
    ?assert(macula_rag_corpus:valid_provenance(Corpus)),
    ?assertNot(macula_rag_corpus:valid_provenance(maps:remove(commit, Corpus))),
    ?assertNot(macula_rag_corpus:valid_provenance(Corpus#{commit => <<"main">>})),
    ?assertNot(macula_rag_corpus:valid_provenance(Corpus#{kind => <<"other">>})),
    ?assertNot(macula_rag_corpus:valid_provenance(Corpus#{content_sha256 => <<"short">>})),
    Deposit = #{kind => <<"deposit">>, path => <<"conversational">>,
                content_sha256 => maps:get(content_sha256, Corpus)},
    ?assert(macula_rag_corpus:valid_provenance(Deposit)),
    ?assertEqual({error, malformed_provenance},
                 macula_rag_corpus:verify_hit((hit(<<"x">>))#{provenance => #{kind => <<"corpus">>}})).

%%% Internals

hit(Text) ->
    #{chunk_id => <<"c1">>, score => 0.9, content => Text,
      provenance => #{kind => <<"corpus">>, repo_id => <<"alpha">>, path => <<"alpha/README.md">>,
                      commit => binary:copy(<<"a">>, 40), start_line => 1, end_line => 3,
                      content_sha256 => binary:encode_hex(crypto:hash(sha256, Text), lowercase)}}.

%% A signed vector as a description: the corpus_hash vector's description, plus
%% the vector's hash, signature and signed_by.
described(#{<<"corpus_hash">> := Hash, <<"signature_base64">> := Sig, <<"signed_by">> := By}) ->
    [#{<<"description">> := Plain}] = maps:get(<<"corpus_hash">>, vectors()),
    (atomized(Plain))#{corpus_hash => Hash, signature => base64:decode(Sig), signed_by => By}.

atomized(#{<<"model">> := M, <<"dim">> := D, <<"repos">> := Repos}) ->
    #{model => M, dim => D,
      repos => [#{id => I, url => U, branch => B, commit => C}
                || #{<<"id">> := I, <<"url">> := U, <<"branch">> := B, <<"commit">> := C} <- Repos]}.

signer(#{<<"signed_by">> := By}) -> binary:decode_hex(By).

profile(#{<<"profile">> := P}) -> binary_to_existing_atom(P).

vectors() -> json:decode(read("corpus.json")).

signed_vectors() -> json:decode(read("signed_corpus.json")).

read(Name) ->
    {ok, Bin} = file:read_file(filename:join(vector_dir(), Name)),
    Bin.

vector_dir() -> climb(filename:dirname(code:which(?MODULE)), 8).

climb(_Dir, 0) -> error(vectors_not_found);
climb(Dir, N) ->
    Candidate = filename:join([Dir, "test", "vectors"]),
    case filelib:is_dir(Candidate) of
        true  -> Candidate;
        false -> climb(filename:dirname(Dir), N - 1)
    end.
