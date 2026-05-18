%%% @doc Publishes shard summaries onto the bloom-advertise channel.
%%%
%%% Every advertise/3 call republishes the summary onto the
%%% summary topic. Receivers on other stations accumulate these in
%%% macula_rag_router state via the subscription set up at
%%% configure/2 time.
-module(macula_rag_advertiser).
-behaviour(gen_server).

-export([start_link/0, advertise/3, withdraw/1, list/0, summary_topic/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    shards = #{} :: #{macula_rag:shard_id() => macula_rag_protocol:summary_msg()}
}).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec advertise(macula_rag:shard_id(), [binary()], binary()) -> ok | {error, term()}.
advertise(ShardId, Topics, Bloom) ->
    gen_server:call(?MODULE, {advertise, ShardId, Topics, Bloom}).

-spec withdraw(macula_rag:shard_id()) -> ok | {error, term()}.
withdraw(ShardId) ->
    gen_server:call(?MODULE, {withdraw, ShardId}).

list() ->
    gen_server:call(?MODULE, list).

-spec summary_topic() -> binary().
summary_topic() ->
    application:get_env(macula_rag, summary_topic, <<"_mesh.rag.summary">>).

%%% gen_server

init([]) ->
    {ok, #state{}}.

handle_call({advertise, ShardId, Topics, Bloom}, _From, #state{shards = M} = S) ->
    Sum = macula_rag_protocol:new_summary(to_bin(ShardId), Topics, Bloom),
    Reply = publish_summary(Sum),
    {reply, Reply, S#state{shards = M#{ShardId => Sum}}};
handle_call({withdraw, ShardId}, _From, #state{shards = M} = S) ->
    Tomb = macula_rag_protocol:new_summary(to_bin(ShardId), [], <<>>),
    Reply = publish_summary(Tomb#{type => summary_withdrawn}),
    {reply, Reply, S#state{shards = maps:remove(ShardId, M)}};
handle_call(list, _From, #state{shards = M} = S) ->
    {reply, maps:values(M), S};
handle_call(_Msg, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _)   -> ok.

%%% Internals

publish_summary(Summary) ->
    case {macula_rag:pool(), macula_rag:realm()} of
        {{ok, Pool}, {ok, Realm}} ->
            try macula:publish(Pool, Realm, summary_topic(), Summary)
            catch C:R -> {error, {publish_failed, C, R}}
            end;
        _ ->
            {error, not_configured}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A)   -> atom_to_binary(A, utf8).
