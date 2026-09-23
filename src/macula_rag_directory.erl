%%% @doc What the org's shards hold: the summaries they publish, this node's
%%% own included.
%%%
%%% Subscribes to the org's two shard facts and keeps the latest summary of
%%% each shard BY ITS VERIFIED PUBLISHER, the node id macula delivered the fact
%%% with, whatever the payload claims. A withdrawal removes it. A summary not
%%% republished within three republish periods is stale and treated as absent,
%%% so a shard that vanished stops being asked for it.
%%%
%%% This node's own summary is published by `advertise/2' and republished every
%%% `summary_republish_ms', so a node that subscribes later still hears it. It
%%% is also kept here directly, under this node's own id, rather than waiting
%%% for the mesh to hand it back.
%%%
%%% A summary is not trust: the shards a query asks are the procedure's
%%% providers, which macula checks against the org's delegations. A summary
%%% from a node that is no provider is never used.
-module(macula_rag_directory).
-behaviour(gen_server).

-export([start_link/0, rebind/0, advertise/2, withdraw/0, summary/1, shards/0, advertised/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(RESUBSCRIBE_MS, 1000).
-define(STALE_PERIODS, 3).

-record(st, {
    %% Each subscription with the pool it was made on and how to end it there:
    %% after a reconfigure the configuration in force names another pool.
    subs = [] :: [{reference(), macula_rag_contract:fact(), pid(), fun()}],
    summaries = #{} :: #{binary() => map()},
    own :: undefined | #{topics := [binary()], bloom := binary()},
    epoch = 0 :: non_neg_integer()
}).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Subscribe under the configuration in force, dropping any earlier
%% subscription, and republish this node's summary if it has one.
-spec rebind() -> ok.
rebind() ->
    gen_server:call(?MODULE, rebind).

-spec advertise([binary()], binary()) -> ok | {error, term()}.
advertise(Topics, Bloom) ->
    gen_server:call(?MODULE, {advertise, Topics, Bloom}).

-spec withdraw() -> ok | {error, term()}.
withdraw() ->
    gen_server:call(?MODULE, withdraw).

%% @doc A shard's live summary, by its node id: `{ok, #{shard_id, embedding,
%% topics, bloom, at_ms}}', or `none'.
-spec summary(binary()) -> {ok, map()} | none.
summary(Node) ->
    gen_server:call(?MODULE, {summary, Node}).

%% @doc Every shard with a live summary, node ids in lowercase hex.
-spec shards() -> [map()].
shards() ->
    gen_server:call(?MODULE, shards).

-spec advertised() -> boolean().
advertised() ->
    gen_server:call(?MODULE, advertised).

%%------------------------------------------------------------------------------
%% gen_server
%%------------------------------------------------------------------------------

init([]) ->
    {ok, #st{}}.

handle_call(rebind, _From, St) ->
    {reply, ok, republished(subscribed(unsubscribed(St)))};
handle_call({advertise, Topics, Bloom}, _From, St) ->
    own_published(publish_own(St#st{own = #{topics => Topics, bloom => Bloom}, epoch = St#st.epoch + 1}));
handle_call(withdraw, _From, St) ->
    {reply, publish_withdrawn(St), forget_own(St#st{own = undefined, epoch = St#st.epoch + 1})};
handle_call({summary, Node}, _From, St) ->
    {reply, live(maps:get(Node, St#st.summaries, undefined), stale_ms()), St};
handle_call(shards, _From, #st{summaries = Summaries} = St) ->
    StaleMs = stale_ms(),
    {reply, [listed(Node, S) || {Node, S} <- maps:to_list(Summaries), live(S, StaleMs) =/= none], St};
handle_call(advertised, _From, #st{own = Own} = St) ->
    {reply, Own =/= undefined, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({macula_event, Ref, _Topic, Payload, #{publisher := Publisher}}, #st{subs = Subs} = St) ->
    {noreply, heard(lists:keyfind(Ref, 1, Subs), Payload, Publisher, St)};
handle_info({macula_event_gone, Ref, _Reason}, #st{subs = Subs} = St) ->
    erlang:send_after(?RESUBSCRIBE_MS, self(), resubscribe),
    {noreply, St#st{subs = lists:keydelete(Ref, 1, Subs)}};
handle_info(resubscribe, St) ->
    {noreply, subscribed(unsubscribed(St))};
handle_info({republish, Epoch}, #st{epoch = Epoch, own = #{}} = St) ->
    {noreply, element(2, publish_own(St))};
handle_info(_Stale, St) ->
    {noreply, St}.

%%------------------------------------------------------------------------------
%% Hearing the org's shards
%%------------------------------------------------------------------------------

heard({_Ref, Fact, _Pool, _Unsubscribe}, Payload, Publisher, St) ->
    applied(Fact, macula_rag_contract:parse(Fact, Payload), Publisher, St);
heard(false, _Payload, _Publisher, St) ->
    St.

applied(shard_summarized, {ok, Summary}, Node, #st{summaries = S} = St) ->
    St#st{summaries = S#{Node => Summary#{received_at => now_ms()}}};
applied(shard_withdrawn, {ok, _}, Node, #st{summaries = S} = St) ->
    St#st{summaries = maps:remove(Node, S)};
applied(_Fact, {error, malformed}, _Node, St) ->
    St.

live(undefined, _StaleMs) -> none;
live(#{received_at := At} = S, StaleMs) -> fresh(now_ms() - At =< StaleMs, S).

fresh(true, S) -> {ok, maps:without([received_at], S)};
fresh(false, _S) -> none.

listed(Node, #{shard_id := ShardId, embedding := Emb, topics := Topics, bloom := Bloom, at_ms := At}) ->
    #{node_id => binary:encode_hex(Node, lowercase), shard_id => ShardId, embedding => Emb,
      topics => Topics, bloom => Bloom, published_at => At}.

stale_ms() -> ?STALE_PERIODS * config_value(summary_republish_ms, 60_000).

%%------------------------------------------------------------------------------
%% Subscribing
%%------------------------------------------------------------------------------

unsubscribed(#st{subs = Subs} = St) ->
    _ = [Unsubscribe(Pool, Ref) || {Ref, _Fact, Pool, Unsubscribe} <- Subs],
    St#st{subs = []}.

subscribed(St) ->
    St#st{subs = each_config(fun subscriptions/1)}.

subscriptions(#{pool := Pool, realm := Realm, realm_name := Name, org := Org,
                io := #{subscribe := Subscribe, unsubscribe := Unsubscribe}}) ->
    [{Ref, Fact, Pool, Unsubscribe}
     || Fact <- [shard_summarized, shard_withdrawn],
        {ok, Ref} <- [Subscribe(Pool, Realm, macula_rag_contract:topic(Name, Org, Fact), self())]].

%% `Fun(Config)' under the configuration in force, or nothing when there is none.
each_config(Fun) -> configured(macula_rag:configuration(), Fun).

configured({ok, Config}, Fun) -> Fun(Config);
configured({error, _}, _Fun) -> [].

config_value(Key, Default) -> value(macula_rag:configuration(), Key, Default).

value({ok, Config}, Key, Default) -> maps:get(Key, Config, Default);
value({error, _}, _Key, Default) -> Default.

%%------------------------------------------------------------------------------
%% This node's own summary
%%------------------------------------------------------------------------------

republished(#st{own = undefined} = St) -> St;
republished(St) -> element(2, publish_own(St)).

own_published({Reply, St}) -> {reply, Reply, St}.

publish_own(St) -> own_publish(macula_rag:configuration(), St).

own_publish({error, _} = NotConfigured, St) ->
    {NotConfigured, St#st{own = undefined}};
own_publish({ok, #{pool := Pool, realm := Realm, realm_name := Name, org := Org, shard_id := ShardId,
                   embedding := Emb, summary_republish_ms := Every, io := Io}},
            #st{own = #{topics := Topics, bloom := Bloom}, epoch = Epoch} = St) ->
    #{publish := Publish, self_node_id := SelfNodeId} = Io,
    Summary = macula_rag_contract:shard_summarized(ShardId, Emb, Topics, Bloom, erlang:system_time(millisecond)),
    Result = Publish(Pool, Realm, macula_rag_contract:topic(Name, Org, shard_summarized), Summary),
    erlang:send_after(Every, self(), {republish, Epoch}),
    {published(Result), kept_own(SelfNodeId(Pool), Summary, St)}.

published(ok) -> ok;
published({error, _} = Failed) -> Failed.

kept_own({ok, Node}, Summary, #st{summaries = S} = St) ->
    {ok, Parsed} = macula_rag_contract:parse(shard_summarized, Summary),
    St#st{summaries = S#{Node => Parsed#{received_at => now_ms()}}};
kept_own(_Unknown, _Summary, St) ->
    St.

publish_withdrawn(_St) ->
    withdrawn_published(macula_rag:configuration()).

withdrawn_published({error, _} = NotConfigured) ->
    NotConfigured;
withdrawn_published({ok, #{pool := Pool, realm := Realm, realm_name := Name, org := Org, shard_id := ShardId,
                           io := #{publish := Publish}}}) ->
    published(Publish(Pool, Realm, macula_rag_contract:topic(Name, Org, shard_withdrawn),
                      macula_rag_contract:shard_withdrawn(ShardId, erlang:system_time(millisecond)))).

forget_own(St) ->
    own_forgotten(macula_rag:configuration(), St).

own_forgotten({ok, #{pool := Pool, io := #{self_node_id := SelfNodeId}}}, St) ->
    forgot(SelfNodeId(Pool), St);
own_forgotten({error, _}, St) ->
    St.

forgot({ok, Node}, #st{summaries = S} = St) -> St#st{summaries = maps:remove(Node, S)};
forgot(_Unknown, St) -> St.

now_ms() -> erlang:monotonic_time(millisecond).
