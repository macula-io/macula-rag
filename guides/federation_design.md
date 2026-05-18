# Federation design

This document expands on the architectural choices in `macula_rag`.

## Why Bloom summaries

A shard with N chunks could advertise its full topic list, but that
grows linearly. A Bloom filter trades exact answers for fixed-size
summaries: 1 KiB summarises ~1 K topics at ~1% false-positive rate.

Receivers union all peer Blooms into a "peer bloom" used by the
router; a query first probes against this union before issuing any
RPC.

## Anti-pattern: centralised vector store

The whole point of `macula_rag` is to avoid a central Qdrant /
pinecone-style service. Realms running this library:

- never need to ship plaintext corpus content across the realm
  (only the shard summary)
- can survive offline shards (router skips them)
- have a clear shape for differential privacy if needed later
  (Bloom is naturally noise-friendly)

## Quorum and hedged requests

The router currently fans to all matching peers and returns
whoever responds before timeout. Two refinements:

1. **Quorum-of-K**: fan to K peers, wait for `ceil(K/2)+1` responses
   before returning. Used when the corpus is sharded with replication.
2. **Hedged**: after p99 latency budget, double the fan-out and
   take whichever wins. Useful at the tail.

Neither is implemented in the scaffold.

## TTL

Peer summaries should expire on a TTL (~5 min) so stations that
drop out cleanly fall off the router's peer set. Macula's existing
liveness signal (peer_observer's last_inbound_at) is the right
ground truth.

## What this library is not

- Not an index. Indexes live in `hecate-vector` or the user's
  choice of vector store.
- Not an embedder. Embeddings live in `hecate-embed` or
  caller-supplied vectors.
- Not opinionated about query shape. Map in, map out.

## Composition

```
hecate-app-rag's serve_retrieval
   ├─ local query: hecate_vector:search via hecate_embed
   └─ federated:    macula_rag:query/2
                       ├─ router picks K peers
                       └─ macula:call (QUIC RPC)
```

The application decides whether to issue a local-only, federated-only,
or merged query.
