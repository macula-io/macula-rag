# macula_rag

Federated retrieval over the [Macula](https://hex.pm/packages/macula) mesh:
ask every shard of an org, merge the answers.

This exists so an index split across many nodes can be searched as one,
without a central server, and without any node the org did not delegate being
able to answer for it.

## What it does

A **shard** is one node holding part of an index. It registers a callback that
searches its part, and publishes a summary of what it holds. A **query** asks
every shard of the org at once and merges their hits by score.

- **The org decides who is a shard.** Every shard provides the procedure
  `<Org>/rag.query_shard_v1`. macula 12 lets a node provide an org's procedure
  only with that org's D25 delegation, and lists a procedure's providers only
  after checking those delegations against the realm key. That checked list is
  the set of shards a query asks. A node the org did not delegate is never
  asked, whatever it publishes.
- **Scores are only merged where they compare.** A shard's summary names the
  embedding its index was built with, model and dimension. A query asks only
  shards with the querying node's own embedding, and says which ones it
  skipped and why.
- **Nothing is dropped silently.** A query answers
  `{ok, Hits, #{answered => [NodeId], failed => [{NodeId, Reason}]}}`. Every
  shard is in one list or the other: `no_summary`, `{embedding_mismatch,
  Theirs}`, `timeout`, `malformed_answer`, or the error the shard answered.
- **One shard per node.** The node id is the shard's identity; `shard_id` is a
  label for people.

It needs **macula 12.1** or later, for `macula:providers/3,4` and the
`provider` option of `macula:call/6`.

## Status

**0.1.0, the first release.** No node issues federated queries in production
yet. What this version does not do:

- The summary carries a **bloom** filter, and `shards/0` lists it, but a query
  does not use it to choose shards: every trusted shard with a matching
  embedding is asked. Bloom-based selection is a later optimisation.
- Trust is the org's delegation list. There is no further per-shard trust
  setting.

## Using it

```erlang
{deps, [{macula_rag, "~> 0.1"}]}.
```

Once a macula pool is connected:

```erlang
ok = macula_rag:configure(Pool, RealmId,
       #{org => <<"acme">>,
         shard_id => <<"library-shard-1">>,
         realm_name => <<"io.macula">>,
         embedding => #{model => <<"nomic-embed-text">>, dim => 768}}),

%% This node is a shard: answer the org's queries.
ok = macula_rag:register_responder(
       fun(Query, #{top_k := K}) -> {ok, my_index:search(Query, K)} end),
ok = macula_rag:advertise([<<"library/books">>], Bloom),

%% Ask every shard of the org.
{ok, Hits, #{answered := Answered, failed := Failed}} =
    macula_rag:query(#{<<"text">> => <<"federated search">>}, #{top_k => 10}).
```

A **hit** needs at least a binary `id` and a numeric `score`; the rest of the
map is yours and is carried as it is. Hits and queries arrive with binary keys,
as every received payload does, and a merged hit also carries `node_id` and
`shard_id`, the shard it came from.

`realm_name` must be the name whose SHA-256 is `RealmId`, or `configure/3`
refuses: the topics carry the name, and a topic naming another realm reaches
nobody.

## The grant

`register_responder/1` advertises the org's procedure as soon as macula grants
it, which needs the org's D25 `procedure_delegation` naming this node. Until
then, `status/0` says why not:

```erlang
#{responder := {not_granted, #{reason := {provider_authorization,
                                          {procedure_delegation, not_found}},
                               since_ms := 42000}}}
```

`{procedure_delegation, not_found}` means an operator has to delegate this node
for the org. The grant is asked for again every `grant_retry_ms` (30 s), so a
delegation made later is picked up without a restart, and advertised once. A
link that drops and comes back needs nothing: macula replays the advertisement
on it.

## Configuration

| Option | Default | Meaning |
|---|---|---|
| `org` | required | whose shards these are; the procedure is `<org>/rag.query_shard_v1` |
| `shard_id` | required | a label for this node's shard |
| `realm_name` | required | the realm's name; its SHA-256 must be the realm id |
| `embedding` | required | `#{model => binary(), dim => pos_integer()}` this node's index uses |
| `query_timeout_ms` | 1500 | how long a query waits for the slowest shard |
| `grant_retry_ms` | 30000 | how often a refused grant is asked for again |
| `summary_republish_ms` | 60000 | how often this shard's summary is republished; a summary unheard for three periods is stale |

## The wire contract

| | |
|---|---|
| procedure | `<org>/rag.query_shard_v1` |
| fact | `<realm>/<org>/rag/shard/shard_summarized_v1`: `shard_id`, `model`, `dim`, `topics`, `bloom`, `at_ms` |
| fact | `<realm>/<org>/rag/shard/shard_withdrawn_v1`: `shard_id`, `at_ms` |
| query | `query`, `top_k`, `model`, `dim` |
| answer | `shard_id`, `model`, `dim`, `hits` |

A summary belongs to the node macula verified as its publisher, whatever the
payload claims. `test/macula_rag_contract_tests.erl` pins every key and reads
each payload back through macula's codec.

## Build and test

    scripts/check.sh      # compile, eunit, lint, xref, dialyzer, as CI runs them

OTP 28.4.3, pinned in `.tool-versions` and CI. The suite includes a federation
test that starts three shard VMs with `peer`: two answer one query and their
hits merge by score; the third, built with another embedding, is reported and
never asked.

## Releasing

A pushed `vX.Y.Z` tag publishes to hex (`.github/workflows/publish-hex.yml`).
Before publishing, the workflow refuses anything but the clean, pushed tag
whose version is in `src/macula_rag.app.src` and has a CHANGELOG section,
dry-runs the publish, and checks that hex.pm accepts the key. After publishing
it checks that hex serves the tagged files.

## Guides

- [Getting started](guides/getting_started.md)
- [Federation design](guides/federation_design.md)

## License

Apache-2.0.
