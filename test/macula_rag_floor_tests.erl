%% @doc The macula this library is built and tested against. macula_rag 1.1
%% is the release on macula 16 (~> 16.0): 16 keeps wire 1.0, the wire every
%% deployed service speaks, and adds the revocation bound (macula#118). A
%% service on macula 16 cannot use a macula_rag that pins macula 15.
-module(macula_rag_floor_tests).

-include_lib("eunit/include/eunit.hrl").

runs_on_macula_16_or_later_test() ->
    _ = application:load(macula),
    {ok, Vsn} = application:get_key(macula, vsn),
    [Major | _] = [list_to_integer(P) || P <- string:split(Vsn, ".", all)],
    ?assertEqual(16, Major).
