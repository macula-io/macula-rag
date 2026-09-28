%% @doc The macula this library is built and tested against. macula_rag 0.2
%% is the release on macula 13 (~> 13.0.1): a service on macula 13 cannot use
%% a macula_rag that pins macula 12. The floor is 13.0.1, where seed() carries
%% the expected_node_id every pinned-seed consumer passes.
-module(macula_rag_floor_tests).

-include_lib("eunit/include/eunit.hrl").

runs_on_macula_13_0_1_or_later_test() ->
    _ = application:load(macula),
    {ok, Vsn} = application:get_key(macula, vsn),
    [Major, Minor, Patch | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    ?assertEqual(13, Major),
    ?assert([Minor, Patch] >= [0, 1]).
