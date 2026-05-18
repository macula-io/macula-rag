%%% @doc Top-level supervisor for macula_rag.
-module(macula_rag_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy  => one_for_one,
        intensity => 10,
        period    => 10
    },
    Children = [
        #{
            id       => macula_rag_advertiser,
            start    => {macula_rag_advertiser, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [macula_rag_advertiser]
        },
        #{
            id       => macula_rag_responder,
            start    => {macula_rag_responder, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [macula_rag_responder]
        },
        #{
            id       => macula_rag_router,
            start    => {macula_rag_router, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [macula_rag_router]
        }
    ],
    {ok, {SupFlags, Children}}.
