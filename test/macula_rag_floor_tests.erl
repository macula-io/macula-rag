%% @doc The macula this library is built and tested against. macula_rag 1.0
%% is the release on macula 15 (~> 15.6), the stable wire: a service on macula
%% 15 cannot use a macula_rag that pins macula 14. The floor is 15.6.0, the
%% SDK base the flag day moves every deployed service to.
-module(macula_rag_floor_tests).

-include_lib("eunit/include/eunit.hrl").

runs_on_macula_15_6_or_later_test() ->
    _ = application:load(macula),
    {ok, Vsn} = application:get_key(macula, vsn),
    [Major, Minor | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    ?assertEqual(15, Major),
    ?assert(Minor >= 6).
