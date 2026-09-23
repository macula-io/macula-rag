# Federation design

Why macula_rag asks the shards it asks, and why it merges what it merges.

## Who is a shard

The obvious design, and the one this library's first scaffold had, is to
listen for summaries and ask whoever published one. It fails in two ways. A
summary is a claim: any node that can publish on the topic can say it holds
anything. And one procedure called once per known shard does not reach the
shards: macula routes an unnamed call to any provider it chooses, so N calls
land wherever the mesh picks.

So the set of shards comes from somewhere a node cannot claim its way into:
**the providers of the org's procedure**, `<org>/rag.query_shard_v1`. macula 12
lets a node provide an org-namespaced procedure only when the org's D25
`procedure_delegation` names it, and `macula:providers/4` lists only providers
whose delegation verifies against the realm key the pool pinned. Each shard is
then called by its node id, with `macula:call/6` and `provider`, so every call
reaches the shard it names and no other.

Summaries are still used, for what only the shard can tell: which embedding it
was built with, and what it holds. A summary from a node that is not a provider
is never used, because that node is never asked.

## Which scores merge

A similarity score means something only against other scores from the same
embedding model and dimension. Merging a 0.8 from one model with a 0.7 from
another produces an order that means nothing, and it looks exactly like a
good result.

So every summary names its embedding, and a query asks only shards whose
embedding matches the querying node's. The shard also names its embedding in
its answer, and an answer in another embedding is refused, in case the summary
and the index disagree. A shard with another embedding is not an error; it is
reported, as `{embedding_mismatch, Theirs}`, so a caller can see that part of
the org's index was not searched.

## Why nothing is dropped

A federated query that quietly returns fewer results when a shard is down is
indistinguishable from one where the other shards simply had nothing. The
caller cannot tell "no match" from "not asked".

So every trusted shard ends in `answered` or in `failed`, with a reason:
`no_summary`, `{embedding_mismatch, Theirs}`, `timeout`, `malformed_answer`,
or the error the shard itself answered. A shard slower than the timeout is
reported and does not hold up the others: each shard is asked in its own
process, and at the deadline the rest are stopped and reported as `timeout`.

## The shard's identity

One node, one shard. The node id macula verified is the shard's identity: it is
what the org delegated, what summaries are filed under, and what a hit's
`node_id` names. `shard_id` is a label for people and is never used to decide
anything, since a node can put anything in it.

## What is left for later

The summary carries a bloom filter over the shard's topics, and `shards/0`
lists it. Using it to skip shards that cannot match would cut the fan-out; it
is not done in 0.1.0, where every trusted shard with a matching embedding is
asked.
