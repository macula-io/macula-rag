%%% @doc Supervises the shard's two servers: the directory of the org's
%%% summaries, and the responder that answers for this node.
-module(macula_rag_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => macula_rag_directory, start => {macula_rag_directory, start_link, []}},
           #{id => macula_rag_responder, start => {macula_rag_responder, start_link, []}}]}}.
