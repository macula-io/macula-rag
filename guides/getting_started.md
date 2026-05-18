# Getting started

`macula_rag` lets multiple stations co-operate on a single search
index without ever centralising it. Each station owns a shard, and
queries route based on Bloom-style summaries advertised on the
Macula mesh.

## Install

```erlang
%% rebar.config
{deps, [
    {macula_rag, "~> 0.1"}
]}.
```

## Three things to wire

```erlang
%% 1. advertise — tell the realm what your shard contains
ok = macula_rag:advertise(
    my_shard,
    [<<"hecate-agents/philosophy">>, <<"hecate-agents/skills">>],
    BloomBytes
).

%% 2. register a responder — handle incoming RPCs
ok = macula_rag:register_responder(my_shard, fun(Query, Opts) ->
    hecate_app_rag:search(Query, Opts)
end).

%% 3. issue queries — fan across peers
{ok, Hits} = macula_rag:query(
    #{q => <<"the dossier moves through desks">>},
    #{top_k => 10, timeout_ms => 1500}
).
```

The `Query` is opaque to `macula_rag` — your responder decides how
to interpret it (text? pre-embedded vector? structured filter?).
The library only deals with routing, fan-out, and result merging.

## Producing the Bloom summary

The library doesn't dictate a bloom-filter implementation. A small,
correct choice: chunk topics + heading words → SHA-256 → set
N bits in a 1 KiB filter. Re-publish on every meaningful index
change (debounce 2 s).

```erlang
Bloom = my_bloom:from_terms(my_index:topics()).
ok    = macula_rag:advertise(my_shard, my_index:topic_list(), Bloom).
```

## Federation patterns

See [federation_design.md](federation_design.md) for the longer
discussion of quorum, TTL, hedged-request, and result-merging policies.
