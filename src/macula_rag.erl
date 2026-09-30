%%% @doc Federated retrieval over the Macula mesh: ask every shard of an org,
%%% merge the answers.
%%%
%%% A SHARD is one node holding part of an index. It answers queries through
%%% `register_responder/1', which provides the org's procedure
%%% `<Org>/rag.query_shard_v1', and says what it holds through `advertise/2'.
%%% One shard per node: the node id is the shard's identity, and the
%%% `shard_id' given to `configure/3' is a label for people.
%%%
%%% A QUERY asks every shard of the org, in parallel, and merges their hits by
%%% score. "Every shard of the org" is macula's own list of the procedure's
%%% providers, which it has checked against the org's D25 delegations, so a
%%% node the org did not delegate is never asked. Only shards built with the
%%% same EMBEDDING (model and dimension) as this node are asked, because scores
%%% from two embeddings do not compare. Nothing is dropped: the result names
%%% every shard that answered and every one that did not, with why.
%%%
%%% A HIT is the consumer's map. Its minimum is a binary `id' and a numeric
%%% `score'; everything else is carried as it is. A merged hit comes back with
%%% binary keys, the ones every received payload has, plus `node_id' and
%%% `shard_id' naming the shard it came from.
%%%
%%% The shard's `bloom' is carried in its summary and listed by `shards/0'; it
%%% is not used to choose shards in this version.
%%%
%%% Start by `configure/3' once the pool is connected.
-module(macula_rag).

-export([configure/3, forget_configuration/0, configuration/0]).
-export([register_responder/1, unregister_responder/0]).
-export([advertise/2, withdraw/0, shards/0]).
-export([query/1, query/2, status/0]).
-export([corpus_hash/1, sign_corpus/2, verify_corpus/3, verify_hit/1]).

-type hit() :: #{binary() => term()}.
-type query_report() :: macula_rag_query:report().
-type responder() :: fun((map(), #{top_k := pos_integer()}) -> {ok, [map()]} | {error, term()}).
-type options() :: #{org := binary(),
                     shard_id := binary(),
                     realm_name := binary(),
                     embedding := macula_rag_contract:embedding(),
                     query_timeout_ms => pos_integer(),
                     grant_retry_ms => pos_integer(),
                     summary_republish_ms => pos_integer(),
                     io => map()}.

-export_type([hit/0, query_report/0, responder/0, options/0]).

-define(CONFIG, {?MODULE, configuration}).
-define(DEFAULTS, #{query_timeout_ms => 1500, grant_retry_ms => 30_000, summary_republish_ms => 60_000}).

%%------------------------------------------------------------------------------
%% Configuration
%%------------------------------------------------------------------------------

%% @doc Bind the library to a connected macula `Pool' and its `Realm' (the
%% 32-byte realm id). `Opts':
%%
%%   org          the org whose shards these are; its procedure is
%%                `<org>/rag.query_shard_v1'
%%   shard_id     a label for this node's shard; the node id is its identity
%%   realm_name   the realm's name, e.g. io.macula; its SHA-256 must be `Realm'
%%   embedding    `#{model => Binary, dim => PosInteger}' this node's index uses
%%
%% and, optionally, `query_timeout_ms' (1500), `grant_retry_ms' (30000), and
%% `summary_republish_ms' (60000). `io' replaces the macula calls, for tests.
%%
%% Configuring again rebinds: the summary subscription moves to the new pool,
%% and a registered responder asks for its grant again.
-spec configure(pid(), <<_:256>>, options()) -> ok | {error, term()}.
configure(Pool, Realm, Opts) when is_pid(Pool), is_binary(Realm), byte_size(Realm) =:= 32, is_map(Opts) ->
    checked(options_checked(Opts), Pool, Realm, Opts).

checked(ok, Pool, Realm, #{realm_name := Name} = Opts) ->
    realm_checked(macula_rag_contract:check_realm_name(Name, Realm), Pool, Realm, Opts);
checked({error, _} = Refused, _Pool, _Realm, _Opts) ->
    Refused.

realm_checked(ok, Pool, Realm, Opts) ->
    Config = maps:merge(?DEFAULTS, Opts#{pool => Pool, realm => Realm,
                                         procedure => macula_rag_contract:procedure(maps:get(org, Opts)),
                                         io => maps:merge(default_io(), maps:get(io, Opts, #{}))}),
    persistent_term:put(?CONFIG, Config),
    ok = macula_rag_directory:rebind(),
    ok = macula_rag_responder:rebind();
realm_checked({error, _} = Refused, _Pool, _Realm, _Opts) ->
    Refused.

options_checked(#{org := Org, shard_id := ShardId, realm_name := Name,
                  embedding := #{model := Model, dim := Dim}})
  when is_binary(ShardId), is_binary(Name), is_binary(Model), is_integer(Dim), Dim > 0 ->
    org_checked(catch macula_rag_contract:procedure(Org));
options_checked(Opts) ->
    {error, {invalid_options, Opts}}.

org_checked(Procedure) when is_binary(Procedure) -> ok;
org_checked({'EXIT', {{invalid_org, Org}, _}}) -> {error, {invalid_org, Org}}.

%% @doc Drop the configuration. Queries and advertising then answer
%% `{error, not_configured}'.
-spec forget_configuration() -> ok.
forget_configuration() ->
    _ = persistent_term:erase(?CONFIG),
    ok.

%% @doc The configuration in force.
-spec configuration() -> {ok, map()} | {error, not_configured}.
configuration() ->
    found(persistent_term:get(?CONFIG, undefined)).

found(undefined) -> {error, not_configured};
found(Config) -> {ok, Config}.

default_io() ->
    #{providers => fun macula:providers/4,
      call => fun macula:call/6,
      publish => fun macula:publish/4,
      subscribe => fun macula:subscribe/4,
      unsubscribe => fun macula:unsubscribe/2,
      advertise => fun macula:advertise/5,
      unadvertise => fun macula:unadvertise/3,
      provider_authorization => fun macula:provider_authorization/3,
      self_node_id => fun self_node_id/1}.

self_node_id(Pool) ->
    status_node_id(macula:status(Pool)).

status_node_id({ok, #{self_node_id := NodeId}}) -> {ok, NodeId}.

%%------------------------------------------------------------------------------
%% This node's shard
%%------------------------------------------------------------------------------

%% @doc Answer the org's queries with `Responder', called with the consumer's
%% query (binary keys, as received) and `#{top_k => K}'. It returns
%% `{ok, Hits}', each hit with at least a binary `id' and a numeric `score', or
%% `{error, Reason}', which the asking node sees as this shard's failure.
%%
%% Registering advertises the procedure as soon as macula grants it: that needs
%% the org's D25 delegation naming this node. Without one, `status/0' reports
%% `{not_granted, ...}' and the grant is asked for again every
%% `grant_retry_ms', so a delegation made later is picked up without a
%% restart. A link that drops and returns needs nothing: macula replays the
%% advertisement on it.
-spec register_responder(responder()) -> ok | {error, not_configured}.
register_responder(Responder) when is_function(Responder, 2) ->
    macula_rag_responder:register(Responder).

-spec unregister_responder() -> ok.
unregister_responder() ->
    macula_rag_responder:unregister().

%% @doc Publish what this shard holds: its topics and a bloom filter over them,
%% with the shard id and embedding from `configure/3'. Republished every
%% `summary_republish_ms' until `withdraw/0', so a node that starts later still
%% hears it. A shard with no summary is not asked.
-spec advertise([binary()], binary()) -> ok | {error, term()}.
advertise(Topics, Bloom) when is_list(Topics), is_binary(Bloom) ->
    macula_rag_directory:advertise(Topics, Bloom).

-spec withdraw() -> ok | {error, term()}.
withdraw() ->
    macula_rag_directory:withdraw().

%% @doc The shards this node has heard a summary from, this one included.
-spec shards() -> [map()].
shards() ->
    macula_rag_directory:shards().

%%------------------------------------------------------------------------------
%% Querying
%%------------------------------------------------------------------------------

-spec query(map()) -> {ok, [hit()], query_report()} | {error, term()}.
query(Query) ->
    query(Query, #{}).

%% @doc Ask every shard of the org built with this node's embedding. `Opts':
%% `top_k' (10), the most hits returned after the merge, and `timeout_ms'
%% (`query_timeout_ms'), how long the slowest shard is waited for.
%%
%% `{ok, Hits, #{answered => [NodeId], failed => [{NodeId, Reason}]}}', node
%% ids in lowercase hex. A shard is `failed' with `no_summary' or
%% `{embedding_mismatch, Theirs}' without being asked, or with `timeout',
%% `malformed_answer', or the error it answered. `{error, {no_shards, Reason}}'
%% when macula lists no provider at all.
-spec query(map(), map()) -> {ok, [hit()], query_report()} | {error, term()}.
query(Query, Opts) when is_map(Query), is_map(Opts) ->
    queried(configuration(), Query, Opts).

queried({error, _} = NotConfigured, _Query, _Opts) ->
    NotConfigured;
queried({ok, #{pool := Pool, realm := Realm, procedure := Proc, embedding := Emb,
               query_timeout_ms := Default, io := Io}}, Query, Opts) ->
    #{providers := Providers, call := Call, self_node_id := SelfNodeId} = Io,
    Timeout = maps:get(timeout_ms, Opts, Default),
    macula_rag_query:run(Query, Opts,
                         #{embedding => Emb,
                           timeout_ms => Default,
                           self => own_node(SelfNodeId(Pool)),
                           providers => fun() -> Providers(Pool, Realm, Proc, Timeout) end,
                           summary => fun macula_rag_directory:summary/1,
                           call => fun(Node, Payload) ->
                                           Call(Pool, Realm, Proc, Payload, Timeout, #{provider => Node})
                                   end,
                           local => fun macula_rag_responder:answer_locally/1}).

own_node({ok, NodeId}) -> NodeId;
own_node(_Unknown) -> undefined.

%%------------------------------------------------------------------------------
%% Status
%%------------------------------------------------------------------------------

%% @doc What this node is doing for the org:
%%
%%   responder    `not_registered', `granted', or `{not_granted, #{reason,
%%                since_ms}}': macula's reason for refusing the grant, as
%%                mcl_om's provider_grants reports it. `{provider_authorization,
%%                {procedure_delegation, not_found}}' means an operator has to
%%                delegate this node for the org.
%%   advertised   whether this shard's summary is being published
%%   shards       how many shards this node has a summary from
-spec status() -> #{responder := term(), advertised := boolean(), shards := non_neg_integer(),
                    configured := boolean()}.
status() ->
    #{responder => macula_rag_responder:status(),
      advertised => macula_rag_directory:advertised(),
      shards => length(macula_rag_directory:shards()),
      configured => element(1, configuration()) =:= ok}.

%%------------------------------------------------------------------------------
%% The RAG service contract: which corpus answered, and who vouches for it
%% (macula_rag_corpus, guides/rag_service_contract.md)
%%------------------------------------------------------------------------------

%% @doc The corpus hash of a provider's description.
-spec corpus_hash(map()) -> binary().
corpus_hash(Description) -> macula_rag_corpus:corpus_hash(Description).

%% @doc A provider's signature over its corpus hash, with its identity key.
-spec sign_corpus(binary(), macula_node_keys:node_key()) -> binary().
sign_corpus(CorpusHash, Key) -> macula_rag_corpus:sign(CorpusHash, Key).

%% @doc Check a description from the provider the caller pinned (macula:call/6
%% with provider), under the caller's profile.
-spec verify_corpus(map(), <<_:256>>, macula_crypto_profile:profile()) -> macula_rag_corpus:verdict().
verify_corpus(Description, Provider, Profile) -> macula_rag_corpus:verify(Description, Provider, Profile).

%% @doc `ok' when a hit's text is the text its provenance hashes.
-spec verify_hit(map()) -> ok | {error, malformed_provenance | content_mismatch}.
verify_hit(Hit) -> macula_rag_corpus:verify_hit(Hit).
