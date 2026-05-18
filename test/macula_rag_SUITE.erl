%%% @doc Smoke tests for macula_rag.
-module(macula_rag_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([advertise_roundtrip/1, register_unregister/1, query_with_no_peers/1]).

all() ->
    [advertise_roundtrip, register_unregister, query_with_no_peers].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(macula_rag),
    Config.

end_per_suite(_Config) ->
    application:stop(macula_rag),
    ok.

advertise_roundtrip(_Config) ->
    ok = macula_rag:advertise(my_shard, [<<"a/b">>, <<"c/d">>], <<0:1024>>),
    Summaries = macula_rag_advertiser:list(),
    ?assert(length(Summaries) >= 1),
    ok = macula_rag:withdraw(my_shard).

register_unregister(_Config) ->
    Fun = fun(_Q, _Opts) -> {ok, []} end,
    ok  = macula_rag:register_responder(my_shard, Fun),
    ok  = macula_rag:unregister_responder(my_shard).

query_with_no_peers(_Config) ->
    {ok, []} = macula_rag:query(#{q => <<"anything">>}, #{top_k => 3, timeout_ms => 100}).
