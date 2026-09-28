# Getting started

This guide takes a node from nothing to answering, and asking, federated
queries for an org.

## What you need

- A macula 13.0.1 pool, connected to the realm, with the realm's key pinned
  (`realm_trust` at `macula:connect/2`). macula uses the pinned key to check
  every shard's delegation.
- The org's **D25 delegation** for this node, if the node is to be a shard.
  A node without one can still query; it cannot answer.
- The embedding your index uses, model and dimension. Scores only compare
  between shards built with the same one.

## 1. Configure

```erlang
{ok, _} = application:ensure_all_started(macula_rag),
ok = macula_rag:configure(Pool, RealmId,
       #{org => <<"acme">>,
         shard_id => <<"acme-docs-eu">>,
         realm_name => <<"io.macula">>,
         embedding => #{model => <<"nomic-embed-text">>, dim => 768}}).
```

`configure/3` refuses a `realm_name` whose SHA-256 is not `RealmId`, and an org
that cannot be a procedure namespace (empty, `_`, or holding a `/`).

## 2. Answer queries

```erlang
ok = macula_rag:register_responder(
       fun(Query, #{top_k := K}) ->
               {ok, [#{id => DocId, score => Score, text => Text}
                     || {DocId, Score, Text} <- my_index:search(Query, K)]}
       end).
```

The callback gets the asking node's query as it arrived, with binary keys, and
returns `{ok, Hits}` or `{error, Reason}`. Each hit needs a binary `id` and a
numeric `score`; a hit without them makes the whole answer
`{error, malformed_hits}` rather than sending something the asker cannot rank.

Then check the grant:

```erlang
macula_rag:status().
%% #{responder => granted, advertised => false, shards => 0, configured => true}
```

`{not_granted, #{reason := ...}}` names macula's reason. With
`{provider_authorization, {procedure_delegation, not_found}}` an operator has
to delegate this node; once they do, the next retry advertises the procedure.

## 3. Say what you hold

```erlang
ok = macula_rag:advertise([<<"acme/docs">>], Bloom).
```

A shard with no summary is not asked: the summary is where the asking node
learns the shard's embedding. It is republished every `summary_republish_ms`,
and `withdraw/0` stops that and tells the other shards.

## 4. Ask

```erlang
{ok, Hits, #{answered := Answered, failed := Failed}} =
    macula_rag:query(#{<<"text">> => <<"where is the invoice template">>},
                     #{top_k => 10, timeout_ms => 2000}).
```

`Hits` are merged by score across every shard that answered, each carrying
`node_id` and `shard_id`. `Failed` names every shard that did not, with why.
`{error, {no_shards, Reason}}` means macula lists no provider for the org's
procedure at all.

If this node is itself a shard, it answers its own query in-process and is
never dialled.
