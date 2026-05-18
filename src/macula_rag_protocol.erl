%%% @doc Wire shape for macula_rag.
%%%
%%% All maps are passed by value through the Macula RPC + pubsub
%%% primitives. Macula encodes them as CBOR — never JSON-encode at
%%% this layer.
-module(macula_rag_protocol).

-export([
    new_query/2,
    new_response/2,
    new_summary/3,
    decode_query/1,
    decode_response/1,
    decode_summary/1
]).

-export_type([query_msg/0, response_msg/0, summary_msg/0]).

-type query_msg() :: #{
    type      := query,
    query_id  := binary(),
    query     := map(),
    top_k     := pos_integer(),
    issued_at := non_neg_integer()
}.

-type response_msg() :: #{
    type     := response,
    query_id := binary(),
    shard_id := binary(),
    hits     := [map()]
}.

-type summary_msg() :: #{
    type      := summary,
    shard_id  := binary(),
    topics    := [binary()],
    bloom     := binary(),
    published_at := non_neg_integer()
}.

-spec new_query(map(), pos_integer()) -> query_msg().
new_query(Query, TopK) ->
    #{
        type      => query,
        query_id  => generate_id(),
        query     => Query,
        top_k     => TopK,
        issued_at => erlang:system_time(millisecond)
    }.

-spec new_response(binary(), [map()]) -> response_msg().
new_response(QueryId, Hits) when is_binary(QueryId), is_list(Hits) ->
    #{type => response, query_id => QueryId, shard_id => self_shard_id(), hits => Hits}.

-spec new_summary(binary(), [binary()], binary()) -> summary_msg().
new_summary(ShardId, Topics, Bloom) ->
    #{
        type         => summary,
        shard_id     => ShardId,
        topics       => Topics,
        bloom        => Bloom,
        published_at => erlang:system_time(millisecond)
    }.

-spec decode_query(map()) -> {ok, query_msg()} | {error, term()}.
decode_query(#{type := query} = M) -> {ok, M};
decode_query(_) -> {error, not_a_query}.

-spec decode_response(map()) -> {ok, response_msg()} | {error, term()}.
decode_response(#{type := response} = M) -> {ok, M};
decode_response(_) -> {error, not_a_response}.

-spec decode_summary(map()) -> {ok, summary_msg()} | {error, term()}.
decode_summary(#{type := summary} = M) -> {ok, M};
decode_summary(_) -> {error, not_a_summary}.

%%% Internals

generate_id() ->
    iolist_to_binary([
        integer_to_binary(erlang:system_time(microsecond)),
        $-,
        integer_to_binary(rand:uniform(16#FFFFFFFF), 16)
    ]).

self_shard_id() ->
    %% TODO: pull from application env. Placeholder until wired.
    atom_to_binary(node(), utf8).
