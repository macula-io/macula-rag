%%% @doc This node's shard answering the org's queries.
%%%
%%% Holds whether the node may provide the org's procedure and advertises it
%%% once it may. macula only lets a node provide an org's procedure when the
%%% org's D25 delegation names it (`macula:provider_authorization/3'). The
%%% responder asks at registration and, while refused, again every
%%% `grant_retry_ms', so a delegation made after the service started is picked
%%% up: it advertises then, once. After that it asks nothing: macula replays the
%%% advertisement itself when a link respawns.
%%%
%%% The callback runs in the process macula calls `handle/1' in, not in this
%%% server, so one slow query holds up no other. It is kept in
%%% persistent_term, written only when a responder registers or unregisters.
-module(macula_rag_responder).
-behaviour(gen_server).

-export([start_link/0, register/1, unregister/0, rebind/0, status/0]).
-export([handle/1, answer_locally/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(RESPONDER, {?MODULE, responder}).

-record(st, {
    grant = not_registered :: not_registered | granted | {not_granted, term(), integer()},
    epoch = 0 :: non_neg_integer()
}).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(macula_rag:responder()) -> ok | {error, not_configured}.
register(Responder) ->
    gen_server:call(?MODULE, {register, Responder}).

-spec unregister() -> ok.
unregister() ->
    gen_server:call(?MODULE, unregister).

%% @doc Called by `macula_rag:configure/3': a registered responder asks for its
%% grant again under the new configuration.
-spec rebind() -> ok.
rebind() ->
    gen_server:call(?MODULE, rebind).

-spec status() -> not_registered | granted | {not_granted, #{reason := term(), since_ms := integer()}}.
status() ->
    gen_server:call(?MODULE, status).

%% @doc The procedure's handler: what macula calls with a query from another
%% shard. Returns this shard's answer, or `{error, Reason}', which macula sends
%% back as the call's error.
-spec handle(term()) -> map() | {error, term()}.
handle(Payload) ->
    handled(macula_rag_contract:parse(query_shard, Payload), macula_rag:configuration(),
            persistent_term:get(?RESPONDER, undefined)).

%% @doc This node's own shard answering this node's query: the same answer a
%% peer would get, through the same codec, so hits read alike whichever shard
%% they came from.
-spec answer_locally(map()) -> {ok, map()} | {error, term()}.
answer_locally(Payload) ->
    locally(handle(wire(Payload))).

locally({error, _} = Refused) -> Refused;
locally(Reply) -> {ok, wire(Reply)}.

wire(Term) -> macula_record_cbor:decode(macula_record_cbor:encode(Term)).

%%------------------------------------------------------------------------------
%% Answering
%%------------------------------------------------------------------------------

handled(_Parsed, _Config, undefined) ->
    {error, no_responder};
handled(_Parsed, {error, _} = NotConfigured, _Responder) ->
    NotConfigured;
handled({error, malformed}, _Config, _Responder) ->
    {error, malformed_query};
handled({ok, #{embedding := Emb, query := Query, top_k := TopK}},
        {ok, #{embedding := Emb, shard_id := ShardId}}, Responder) ->
    answered(Responder(Query, #{top_k => TopK}), ShardId, Emb);
handled({ok, #{embedding := _Other}}, {ok, _Config}, _Responder) ->
    {error, embedding_mismatch}.

answered({ok, Hits}, ShardId, Emb) when is_list(Hits) ->
    hits_checked(lists:all(fun macula_rag_contract:valid_hit/1, Hits), ShardId, Emb, Hits);
answered({error, _} = Refused, _ShardId, _Emb) ->
    Refused;
answered(_Other, _ShardId, _Emb) ->
    {error, malformed_hits}.

hits_checked(true, ShardId, Emb, Hits) -> macula_rag_contract:shard_answered(ShardId, Emb, Hits);
hits_checked(false, _ShardId, _Emb, _Hits) -> {error, malformed_hits}.

%%------------------------------------------------------------------------------
%% gen_server: the grant
%%------------------------------------------------------------------------------

init([]) ->
    {ok, #st{}}.

handle_call({register, Responder}, _From, St) ->
    persistent_term:put(?RESPONDER, Responder),
    reply_granting(macula_rag:configuration(), St);
handle_call(rebind, _From, #st{grant = not_registered} = St) ->
    {reply, ok, St};
handle_call(rebind, _From, St) ->
    reply_granting(macula_rag:configuration(), St);
handle_call(unregister, _From, St) ->
    _ = persistent_term:erase(?RESPONDER),
    withdrawn(St#st.grant, macula_rag:configuration()),
    {reply, ok, St#st{grant = not_registered, epoch = St#st.epoch + 1}};
handle_call(status, _From, St) ->
    {reply, reported(St#st.grant), St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

%% A retry armed under an earlier registration or configuration is stale.
handle_info({retry_grant, Epoch}, #st{epoch = Epoch, grant = {not_granted, _, _}} = St) ->
    {noreply, granting(macula_rag:configuration(), St)};
handle_info({retry_grant, _Stale}, St) ->
    {noreply, St}.

reply_granting({error, _} = NotConfigured, St) ->
    {reply, NotConfigured, St};
reply_granting({ok, _} = Config, St) ->
    {reply, ok, granting(Config, St#st{epoch = St#st.epoch + 1})}.

granting({ok, #{pool := Pool, realm := Realm, procedure := Proc, io := Io} = Config}, St) ->
    #{provider_authorization := Authorization, advertise := Advertise} = Io,
    after_attempt(advertised(Authorization(Pool, Realm, Proc), Advertise, Pool, Realm, Proc), Config, St);
granting({error, _}, St) ->
    St.

%% Asked first, so a node without its grant is told why rather than getting
%% whatever advertise/5 would fail with.
advertised({ok, _Authorization}, Advertise, Pool, Realm, Proc) ->
    Advertise(Pool, Realm, Proc, {?MODULE, handle}, #{});
advertised({error, _} = Refused, _Advertise, _Pool, _Realm, _Proc) ->
    Refused.

after_attempt(ok, _Config, St) ->
    St#st{grant = granted};
after_attempt({error, Reason}, #{grant_retry_ms := RetryMs}, #st{epoch = Epoch} = St) ->
    erlang:send_after(RetryMs, self(), {retry_grant, Epoch}),
    St#st{grant = {not_granted, Reason, since(St#st.grant)}}.

%% The window runs from the FIRST refusal of an unbroken run, as mcl_om's does.
since({not_granted, _Reason, Since}) -> Since;
since(_GrantedOrNew) -> erlang:monotonic_time(millisecond).

withdrawn(granted, {ok, #{pool := Pool, realm := Realm, procedure := Proc, io := #{unadvertise := Unadvertise}}}) ->
    _ = Unadvertise(Pool, Realm, Proc),
    ok;
withdrawn(_NotAdvertised, _Config) ->
    ok.

reported({not_granted, Reason, Since}) ->
    {not_granted, #{reason => Reason, since_ms => erlang:monotonic_time(millisecond) - Since}};
reported(Grant) ->
    Grant.
