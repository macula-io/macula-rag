# macula-rag

Federated semantic retrieval over the Macula mesh.

A protocol + small Erlang library that lets a station offer a slice of
a corpus as a queryable RAG shard, and lets another station fan a
query across the realm without knowing where any particular chunk
lives. Stations announce a Bloom-style summary of their index via the
existing mesh advertisement channel; queries route via Macula's RPC
primitive.

## Status

**Scaffold.** Wire shape, supervisor tree, public facade, and
callback contract are in place. Wire-level integration with
`macula` (SDK) is stubbed out and marked `TODO`.

## Why a separate library

`hecate-app-rag` runs a single local index against the local corpus.
`macula-rag` is the realm-agnostic protocol layer that:

- advertises this station's shard summary (Bloom of chunk topics)
- listens for incoming retrieval RPCs
- delegates the local search to a user-supplied callback
  (typically `hecate-app-rag`)
- fans an outgoing query across peers based on advertised summaries
- merges + ranks the partial results

Other consumers (non-Hecate apps, agents, demo stations) can plug
their own search callback in.

## Architecture

```
                       ┌──── Macula RPC ────┐
                       │                    │
   station A           ▼                    │           station B
   ───────────────────────                   ───────────────────────
   macula_rag_router                         macula_rag_responder
   (fans query out)                          (handles incoming RPC)
        │                                          │
        │ knows from peer_blooms                    │ delegates to
        │ which stations are                        │ user-supplied
        │ worth asking                              │ search_callback
        ▼                                          ▼
   peer_summaries                              search_callback
   (advertised via                             (e.g. hecate_app_rag)
    _mesh.bloom topic)
```

## Public API

```erlang
%% advertise our shard's summary into the realm
ok = macula_rag:advertise(
    my_shard,
    [<<"hecate-corpus/philosophy">>, <<"hecate-corpus/skills">>],
    BloomBytes
).

%% answer remote queries by delegating to a callback
ok = macula_rag:register_responder(
    my_shard,
    fun(Query, Opts) -> hecate_app_rag:search(Query, Opts) end
).

%% issue a federated query
{ok, Hits} = macula_rag:query(<<"the dossier moves through desks">>, #{
    top_k => 10,
    timeout_ms => 1500
}).
```

The library treats `Query` as an opaque map: it's the responder's job
to handle text-vs-vector queries, filters, etc.

## Dependencies

- [`macula`](https://codeberg.org/macula-io/macula) (SDK) - QUIC RPC, pub/sub, bloom-advertise channel
- (downstream) `hecate-app-rag` - typical responder

## Build

```bash
rebar3 compile
rebar3 ct
```

## License

Apache-2.0. See [LICENSE](LICENSE).
