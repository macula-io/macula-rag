%% @doc The macula this library is built and tested against. macula_rag 2.0
%% is the release on macula 18 (~> 18.0): 18 keeps wire 1.0, the wire every
%% deployed service speaks, and removes `subscribe/4' (macula#147). A library
%% that binds a function its macula no longer exports dies the first time it
%% calls it (macula-rag#3), so every macula call it makes is checked here.
-module(macula_rag_floor_tests).

-include_lib("eunit/include/eunit.hrl").

runs_on_macula_18_or_later_test() ->
    _ = application:load(macula),
    {ok, Vsn} = application:get_key(macula, vsn),
    [Major | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    ?assertEqual(18, Major).

every_macula_call_is_exported_by_the_macula_in_use_test() ->
    Missing = [{Name, M, F, A} || {Name, Fun} <- maps:to_list(macula_rag:default_io()),
                                  {type, external} <- [erlang:fun_info(Fun, type)],
                                  {module, M} <- [erlang:fun_info(Fun, module)],
                                  {name, F} <- [erlang:fun_info(Fun, name)],
                                  {arity, A} <- [erlang:fun_info(Fun, arity)],
                                  not exported(M, F, A)],
    ?assertEqual([], Missing).

exported(M, F, A) ->
    {module, M} = code:ensure_loaded(M),
    erlang:function_exported(M, F, A).
