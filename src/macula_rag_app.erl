%%% @doc The macula_rag application. It starts unconfigured; `macula_rag:configure/3'
%%% binds it to a pool.
-module(macula_rag_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    macula_rag_sup:start_link().

stop(_State) ->
    macula_rag:forget_configuration().
