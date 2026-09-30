#!/usr/bin/env escript
%%! -noshell
%% Makes test/vectors/signed_corpus.json: a synthetic corpus description signed
%% the way the RAG service contract says (macula_signed_object over
%% {corpus_hash}, label "macula-rag corpus v1", key carried), once per profile,
%% with a freshly generated key. Written with macula alone, so the vector does
%% not depend on macula_rag_corpus. Run once from the repo root after
%% `rebar3 compile':  escript scripts/make_signed_corpus_vectors.escript
main(_) ->
    [code:add_patha(D) || D <- filelib:wildcard("_build/default/lib/*/ebin")],
    {ok, _} = application:ensure_all_started(crypto),
    Hash = <<"0d5f037bfa41e1bce262d87098576102063fa084f63441a348d2a7648b4b2644">>,
    Vectors = [vector(Profile, Hash) || Profile <- [pq_pure, pq_hybrid]],
    Json = iolist_to_binary(["[\n", lists:join(",\n", Vectors), "\n]\n"]),
    ok = filelib:ensure_dir("test/vectors/signed_corpus.json"),
    ok = file:write_file("test/vectors/signed_corpus.json", Json),
    io:format("wrote test/vectors/signed_corpus.json~n").

vector(Profile, Hash) ->
    {ok, Key} = macula_node_keys:generate(identity, Profile),
    {ok, NodeId} = macula_node_keys:node_id(Key),
    Object = macula_signed_object:sign(<<"macula-rag corpus v1">>,
                                       #{{text, <<"corpus_hash">>} => {text, Hash}}, Key),
    Signature = macula_signed_object:encode(Object),
    io_lib:format("  {\"profile\": \"~s\", \"signed_by\": \"~s\", \"corpus_hash\": \"~s\",~n"
                  "   \"signature_base64\": \"~s\"}",
                  [Profile, binary:encode_hex(NodeId, lowercase), Hash, base64:encode(Signature)]).
