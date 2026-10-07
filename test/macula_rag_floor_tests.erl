%% @doc The macula this library is built and tested against. macula_rag 0.4
%% is the release on macula 14 (~> 14.2): a service on macula 14 cannot use
%% a macula_rag that pins macula 13. The floor is 14.2.0, the SDK base every
%% deployed service moves to.
-module(macula_rag_floor_tests).

-include_lib("eunit/include/eunit.hrl").

runs_on_macula_14_2_or_later_test() ->
    _ = application:load(macula),
    {ok, Vsn} = application:get_key(macula, vsn),
    [Major, Minor | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    ?assertEqual(14, Major),
    ?assert(Minor >= 2).
