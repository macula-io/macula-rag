%%% @doc The wire contract every shard of an org speaks. Pure.
%%%
%%% ONE PROCEDURE, `<Org>/rag.query_shard_v1'. Each shard node provides it
%%% under its org's namespace, so macula 12 only lets a node provide it with a
%%% D25 `procedure_delegation' from that org, and only calls a provider whose
%%% delegation verifies against the realm key. That is what makes "the shards
%%% of this org" a checked set rather than whoever says so.
%%%
%%% TWO FACTS, canonical app facts under the org:
%%%
%%%   `<realm>/<org>/rag/shard/shard_summarized_v1'  what a shard holds
%%%   `<realm>/<org>/rag/shard/shard_withdrawn_v1'   it holds nothing any more
%%%
%%% A summary names the EMBEDDING the shard's index was built with, model and
%%% dimension. Scores from two embeddings are not comparable, so a query is
%%% only sent to, and only merged across, shards whose embedding matches the
%%% querying node's own.
%%%
%%% WHO SENT A FACT IS NOT IN THE PAYLOAD. macula delivers every event with its
%%% verified publisher; a summary belongs to that node, whatever it claims.
%%% `shard_id' is informational: the node id is the shard's identity.
%%%
%%% A HIT'S MINIMUM is a binary `id' and a numeric `score'. Everything else in a
%%% hit, and the whole query, is the consumer's, carried as it is.
%%%
%%% Build functions take atom keys. `parse/2' reads what a peer receives, where
%%% macula's codec hands text back as `{text, Binary}': received maps, the
%%% consumer's query and hits included, come back with binary keys.
-module(macula_rag_contract).

-export([procedure/1, topic/3, check_realm_name/2]).
-export([shard_summarized/5, shard_withdrawn/2, query_shard/3, shard_answered/3]).
-export([parse/2, valid_hit/1, plain/1]).

-type embedding() :: #{model := binary(), dim := pos_integer()}.
-type fact() :: shard_summarized | shard_withdrawn.
-type kind() :: fact() | query_shard | shard_answered.

-export_type([embedding/0, fact/0, kind/0]).

-define(PROCEDURE_NAME, <<"rag.query_shard_v1">>).
-define(APP, <<"rag">>).
-define(DOMAIN, <<"shard">>).

%%------------------------------------------------------------------------------
%% Names
%%------------------------------------------------------------------------------

%% @doc The procedure every shard of `Org' provides. An org that would not
%% parse back as the namespace (empty, `_', or holding a `/') is refused.
-spec procedure(binary()) -> binary().
procedure(Org) ->
    named(valid_org(Org), Org).

named(true, Org) -> <<Org/binary, "/", ?PROCEDURE_NAME/binary>>;
named(false, Org) -> error({invalid_org, Org}).

valid_org(Org) when is_binary(Org), Org =/= <<>>, Org =/= <<"_">> ->
    binary:match(Org, <<"/">>) =:= nomatch;
valid_org(_) ->
    false.

-spec topic(binary(), binary(), fact()) -> binary().
topic(RealmName, Org, Fact) ->
    macula_topic:app_fact(RealmName, Org, ?APP, ?DOMAIN, atom_to_binary(Fact, utf8), 1).

%% @doc The realm NAME the topics carry must be the realm the pool uses: a
%% topic naming another realm reaches nobody.
-spec check_realm_name(binary(), <<_:256>>) -> ok | {error, {realm_name_mismatch, binary()}}.
check_realm_name(Name, Realm) ->
    realm_matched(crypto:hash(sha256, Name) =:= Realm, Name).

realm_matched(true, _Name) -> ok;
realm_matched(false, Name) -> {error, {realm_name_mismatch, Name}}.

%%------------------------------------------------------------------------------
%% Build
%%------------------------------------------------------------------------------

-spec shard_summarized(binary(), embedding(), [binary()], binary(), integer()) -> map().
shard_summarized(ShardId, #{model := Model, dim := Dim}, Topics, Bloom, AtMs) ->
    #{shard_id => ShardId, model => Model, dim => Dim, topics => Topics, bloom => Bloom,
      at_ms => AtMs}.

-spec shard_withdrawn(binary(), integer()) -> map().
shard_withdrawn(ShardId, AtMs) ->
    #{shard_id => ShardId, at_ms => AtMs}.

-spec query_shard(map(), pos_integer(), embedding()) -> map().
query_shard(Query, TopK, #{model := Model, dim := Dim}) ->
    #{query => Query, top_k => TopK, model => Model, dim => Dim}.

-spec shard_answered(binary(), embedding(), [map()]) -> map().
shard_answered(ShardId, #{model := Model, dim := Dim}, Hits) ->
    #{shard_id => ShardId, model => Model, dim => Dim, hits => Hits}.

%% @doc A hit carries at least a binary `id' and a numeric `score', under atom
%% or binary keys.
-spec valid_hit(term()) -> boolean().
valid_hit(Hit) when is_map(Hit) ->
    minimum(field(id, Hit), field(score, Hit));
valid_hit(_) ->
    false.

minimum(Id, Score) -> is_binary(Id) andalso is_number(Score).

field(Key, Hit) -> maps:get(Key, Hit, maps:get(atom_to_binary(Key, utf8), Hit, undefined)).

%%------------------------------------------------------------------------------
%% Parse: what a peer receives
%%------------------------------------------------------------------------------

%% @doc Read a received payload as `Kind'. `{error, malformed}' for anything
%% without the contract's keys and types; a consumer drops those rather than
%% crash on another node's bad frame.
-spec parse(kind(), term()) -> {ok, map()} | {error, malformed}.
parse(Kind, Payload) when is_map(Payload) ->
    read(Kind, plain(Payload));
parse(_Kind, _Payload) ->
    {error, malformed}.

read(shard_summarized, #{<<"shard_id">> := S, <<"model">> := M, <<"dim">> := D,
                         <<"topics">> := T, <<"bloom">> := B, <<"at_ms">> := At})
  when is_binary(S), is_binary(M), is_integer(D), D > 0, is_list(T), is_binary(B), is_integer(At) ->
    all_binaries(T, #{shard_id => S, embedding => #{model => M, dim => D}, topics => T, bloom => B,
                      at_ms => At});
read(shard_withdrawn, #{<<"shard_id">> := S, <<"at_ms">> := At}) when is_binary(S), is_integer(At) ->
    {ok, #{shard_id => S, at_ms => At}};
read(query_shard, #{<<"query">> := Q, <<"top_k">> := K, <<"model">> := M, <<"dim">> := D})
  when is_map(Q), is_integer(K), K > 0, is_binary(M), is_integer(D), D > 0 ->
    {ok, #{query => Q, top_k => K, embedding => #{model => M, dim => D}}};
read(shard_answered, #{<<"shard_id">> := S, <<"model">> := M, <<"dim">> := D, <<"hits">> := H})
  when is_binary(S), is_binary(M), is_integer(D), D > 0, is_list(H) ->
    hits_valid(lists:all(fun valid_hit/1, H),
               #{shard_id => S, embedding => #{model => M, dim => D}, hits => H});
read(_Kind, _Plain) ->
    {error, malformed}.

all_binaries(List, Parsed) -> checked(lists:all(fun is_binary/1, List), Parsed).

hits_valid(Valid, Parsed) -> checked(Valid, Parsed).

checked(true, Parsed) -> {ok, Parsed};
checked(false, _Parsed) -> {error, malformed}.

%% `{text, B}' back to `B', and atoms to binaries, at any depth, so a received
%% payload reads like a built one with binary keys.
-spec plain(term()) -> term().
plain({text, B}) when is_binary(B) -> B;
plain(M) when is_map(M) -> maps:from_list([{plain(K), plain(V)} || {K, V} <- maps:to_list(M)]);
plain(L) when is_list(L) -> [plain(E) || E <- L];
plain(A) when is_atom(A), A =/= undefined -> atom_to_binary(A, utf8);
plain(V) -> V.
