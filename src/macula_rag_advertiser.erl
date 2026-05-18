%%% @doc Publishes shard summaries onto the bloom-advertise channel.
%%%
%%% The realm sees, per station, what topics and Bloom summary each
%%% shard offers. Router peers on the receiving side use this to pick
%%% which stations to ask when a query lands.
-module(macula_rag_advertiser).
-behaviour(gen_server).

-export([start_link/0, advertise/3, withdraw/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    shards = #{} :: #{macula_rag:shard_id() => macula_rag_protocol:summary_msg()}
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec advertise(macula_rag:shard_id(), [binary()], binary()) -> ok.
advertise(ShardId, Topics, Bloom) ->
    gen_server:call(?MODULE, {advertise, ShardId, Topics, Bloom}).

-spec withdraw(macula_rag:shard_id()) -> ok.
withdraw(ShardId) ->
    gen_server:call(?MODULE, {withdraw, ShardId}).

list() ->
    gen_server:call(?MODULE, list).

%%% gen_server

init([]) ->
    %% TODO: subscribe to topology changes from macula so we re-publish
    %% on rejoin.
    {ok, #state{}}.

handle_call({advertise, ShardId, Topics, Bloom}, _From, #state{shards = M} = S) ->
    Sum = macula_rag_protocol:new_summary(to_bin(ShardId), Topics, Bloom),
    publish_summary(Sum),
    {reply, ok, S#state{shards = M#{ShardId => Sum}}};
handle_call({withdraw, ShardId}, _From, #state{shards = M} = S) ->
    %% TODO: publish a withdrawal marker; receivers expire on TTL too.
    {reply, ok, S#state{shards = maps:remove(ShardId, M)}};
handle_call(list, _From, #state{shards = M} = S) ->
    {reply, maps:values(M), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _)   -> ok.

%%% Internals

publish_summary(_Summary) ->
    %% TODO: macula:publish(Client, Topic, _Summary). Wait for the macula
    %% client handle to be wired in via application env.
    ok.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8).
