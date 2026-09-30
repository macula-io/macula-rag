%%% @doc The RAG service contract's corpus identity: which corpus answered, and
%%% who vouches for it. Pure. guides/rag_service_contract.md is the canonical
%%% text, and test/vectors carries its frozen vectors.
%%%
%%% CORPUS HASH. A provider describes its corpus as its embedding (`model',
%%% `dim') and its `repos', each an `id', `url', `branch' and the pinned
%%% `commit'. corpus_hash is the lowercase hex sha256 of the RFC 8785 canonical
%%% JSON of `{"dim", "model", "repos": [{"branch", "commit", "id", "url"}]}',
%%% repos in list order. The same repos in another embedding are another corpus.
%%%
%%% THE OPERATOR'S SIGNATURE is optional. When present it is a
%%% macula_signed_object, carrying its key, over `{corpus_hash}' under the label
%%% signature_label/0. It is static: any provider can serve a copy. So a caller
%%% counts a corpus as signed by P only when it called P itself (macula:call/6
%%% with `#{provider => P}'), and verify/3 is the whole check: the description
%%% hashes to what it claims, the object verifies under the label and the
%%% caller's profile, the node id derived from the VERIFIED key is P, and the
%%% signed hash is the recomputed one. `signed_by' in a description is a display
%%% label and never read here.
%%%
%%% PROVENANCE. Every hit says where its text came from: `kind' `corpus' (with
%%% `repo_id' and the 40-hex `commit' it was ingested at) or `deposit', its
%%% `path', and `content_sha256', the sha256 of the text. verify_hit/1 checks the
%%% text against that hash; it says nothing about whether the provider told the
%%% truth about the repo, which is what the signed corpus is for.
-module(macula_rag_corpus).

-export([corpus_hash/1, canonical_json/1, signature_label/0, sign/2, verify/3,
         verify_hit/1, valid_provenance/1]).

-type verdict() :: {ok, unsigned | {signed, <<_:256>>}} |
                   {error, malformed_description | corpus_hash_mismatch | signer_not_provider |
                           signature_hash_mismatch | {signature, term()}}.
-export_type([verdict/0]).

-define(LABEL, <<"macula-rag corpus v1">>).
-define(HASH_FIELD, {text, <<"corpus_hash">>}).
-define(REPO_KEYS, [<<"id">>, <<"url">>, <<"branch">>, <<"commit">>]).

%% @doc The label a corpus signature is made under.
-spec signature_label() -> binary().
signature_label() -> ?LABEL.

%% @doc The corpus hash of a description (built or as received).
-spec corpus_hash(map()) -> binary().
corpus_hash(Description) ->
    #{<<"model">> := Model, <<"dim">> := Dim, <<"repos">> := Repos} =
        macula_rag_contract:plain(Description),
    Identity = #{<<"dim">> => Dim, <<"model">> => Model,
                 <<"repos">> => [maps:with(?REPO_KEYS, R) || R <- Repos]},
    hex(crypto:hash(sha256, canonical_json(Identity))).

%% @doc A provider's signature over its corpus hash, with its identity key: the
%% encoded macula_signed_object, bytes on the wire.
-spec sign(binary(), macula_node_keys:node_key()) -> binary().
sign(CorpusHash, Key) when is_binary(CorpusHash) ->
    macula_signed_object:encode(
        macula_signed_object:sign(?LABEL, #{?HASH_FIELD => {text, CorpusHash}}, Key)).

%% @doc Check a description from the provider the caller pinned, under the
%% caller's profile. `{ok, unsigned}' when it carries no signature.
-spec verify(map(), <<_:256>>, macula_crypto_profile:profile()) -> verdict().
verify(Description, Provider, Profile) when is_map(Description) ->
    described(well_formed(macula_rag_contract:plain(Description)), Provider, Profile).

described({ok, #{<<"corpus_hash">> := Claimed} = D}, Provider, Profile) ->
    hashed(corpus_hash(D) =:= Claimed, D, Provider, Profile);
described(error, _Provider, _Profile) ->
    {error, malformed_description}.

hashed(false, _D, _Provider, _Profile) ->
    {error, corpus_hash_mismatch};
hashed(true, #{<<"signature">> := Signature, <<"corpus_hash">> := Hash}, Provider, Profile) ->
    object(macula_signed_object:decode(Signature), Hash, Provider, Profile);
hashed(true, _Unsigned, _Provider, _Profile) ->
    {ok, unsigned}.

object({ok, Object}, Hash, Provider, Profile) ->
    verified(macula_signed_object:verify(?LABEL, Object, Profile), Hash, Provider, Profile);
object({error, Reason}, _Hash, _Provider, _Profile) ->
    {error, {signature, Reason}}.

verified({ok, #{key := Key, fields := Fields}}, Hash, Provider, Profile) ->
    signer(macula_node_keys:node_id(Key, Profile) =:= Provider, maps:get(?HASH_FIELD, Fields, none),
           Hash, Provider);
verified({error, Reason}, _Hash, _Provider, _Profile) ->
    {error, {signature, Reason}}.

signer(false, _Signed, _Hash, _Provider)          -> {error, signer_not_provider};
signer(true, {text, Hash}, Hash, Provider)        -> {ok, {signed, Provider}};
signer(true, _OtherHash, _Hash, _Provider)        -> {error, signature_hash_mismatch}.

%% Exactly what the hash covers must be there, well typed; a signature, when
%% present, is bytes.
well_formed(#{<<"model">> := M, <<"dim">> := D, <<"repos">> := Repos, <<"corpus_hash">> := H} = Desc)
  when is_binary(M), is_integer(D), D > 0, is_list(Repos), is_binary(H) ->
    ok_if(lists:all(fun repo/1, Repos) andalso signature_bytes(Desc), Desc);
well_formed(_Other) ->
    error.

repo(#{<<"id">> := I, <<"url">> := U, <<"branch">> := B, <<"commit">> := C}) ->
    lists:all(fun is_binary/1, [I, U, B, C]);
repo(_Other) ->
    false.

signature_bytes(#{<<"signature">> := S}) -> is_binary(S);
signature_bytes(_Unsigned)                -> true.

ok_if(true, Desc)  -> {ok, Desc};
ok_if(false, _Desc) -> error.

%% @doc `ok' when a hit's text is the text its provenance hashes.
-spec verify_hit(map()) -> ok | {error, malformed_provenance | content_mismatch}.
verify_hit(Hit) when is_map(Hit) ->
    hit(macula_rag_contract:plain(Hit)).

hit(#{<<"content">> := Content, <<"provenance">> := P}) when is_binary(Content) ->
    provenance_checked(valid_provenance(P), Content, P);
hit(_Other) ->
    {error, malformed_provenance}.

provenance_checked(true, Content, #{<<"content_sha256">> := Sha}) ->
    content(hex(crypto:hash(sha256, Content)) =:= Sha);
provenance_checked(false, _Content, _P) ->
    {error, malformed_provenance}.

content(true)  -> ok;
content(false) -> {error, content_mismatch}.

%% @doc Whether a provenance has the contract's shape: corpus content names its
%% repo and 40-hex commit, a deposit names neither; both name a path and the
%% 64-hex sha256 of the text.
-spec valid_provenance(term()) -> boolean().
valid_provenance(P) when is_map(P) ->
    shaped(macula_rag_contract:plain(P));
valid_provenance(_Other) ->
    false.

shaped(#{<<"kind">> := <<"corpus">>, <<"path">> := Path, <<"repo_id">> := Repo,
         <<"commit">> := Commit, <<"content_sha256">> := Sha})
  when is_binary(Path), is_binary(Repo), Repo =/= <<>> ->
    hex_of(Commit, 40) andalso hex_of(Sha, 64);
shaped(#{<<"kind">> := <<"deposit">>, <<"path">> := Path, <<"content_sha256">> := Sha} = P)
  when is_binary(Path) ->
    hex_of(Sha, 64) andalso not maps:is_key(<<"repo_id">>, P) andalso not maps:is_key(<<"commit">>, P);
shaped(_Other) ->
    false.

hex_of(V, Len) when is_binary(V), byte_size(V) =:= Len ->
    re:run(V, <<"^[0-9a-f]+$">>, [dollar_endonly]) =/= nomatch;
hex_of(_V, _Len) ->
    false.

%% @doc RFC 8785 canonical JSON for what a corpus identity holds: objects with
%% binary keys (sorted; ASCII keys, where UTF-16 code-unit order is byte
%% order), arrays, strings and integers.
-spec canonical_json(map() | list() | binary() | integer()) -> binary().
canonical_json(M) when is_map(M) ->
    Members = [[string(K), $:, canonical_json(V)] || {K, V} <- lists:sort(maps:to_list(M))],
    iolist_to_binary([${, lists:join($,, Members), $}]);
canonical_json(L) when is_list(L) ->
    iolist_to_binary([$[, lists:join($,, [canonical_json(V) || V <- L]), $]]);
canonical_json(B) when is_binary(B) ->
    string(B);
canonical_json(I) when is_integer(I) ->
    integer_to_binary(I).

string(B) ->
    iolist_to_binary([$", [escape(C) || <<C>> <= B], $"]).

escape($")  -> <<"\\\"">>;
escape($\\) -> <<"\\\\">>;
escape($\b) -> <<"\\b">>;
escape($\f) -> <<"\\f">>;
escape($\n) -> <<"\\n">>;
escape($\r) -> <<"\\r">>;
escape($\t) -> <<"\\t">>;
escape(C) when C < 16#20 -> io_lib:format("\\u~4.16.0b", [C]);
escape(C)   -> C.

hex(Bin) -> binary:encode_hex(Bin, lowercase).
