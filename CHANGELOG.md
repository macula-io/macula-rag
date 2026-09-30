# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project adheres to [Semantic Versioning](https://semver.org/).

## [0.3.0] - 2026-10-01

### Added

- **The RAG service contract** (`guides/rag_service_contract.md`, canonical,
  with frozen vectors in `test/vectors/`): the five procedures a provider
  serves, provenance on every hit, the corpus hash and the operator's
  optional signature.
- `macula_rag_corpus`, through the facade: `corpus_hash/1`, `sign_corpus/2`,
  `verify_corpus/3` (signed only by the pinned provider, from the verified
  key, over the recomputed hash) and `verify_hit/1`.
- `macula_rag_contract:plain/1` is exported: a received payload with text
  unwrapped and atom keys as binaries.

## [0.2.0] - 2026-09-29

### Changed

- **On macula 13** (`~> 13.0.1`, was `~> 12.1`). A service on macula 13 could
  not use macula_rag 0.1, which pinned macula 12. No code change was needed:
  the facade calls it makes (`advertise`, `unadvertise`, `call`, `providers`,
  `publish`, `subscribe`, `unsubscribe`, `status`, `provider_authorization`)
  compile, pass xref and dialyzer, and the whole suite passes on 13.0.1.
- A test holds the floor: macula 13.0.1 or later.

## [0.1.0] - 2026-09-23

The first release. Everything before it was an unreleased scaffold on macula
10, which this replaces.

### Added

- Federated query across an org's shards: `macula_rag:query/1,2` asks every
  shard in parallel and merges hits by score, returning
  `{ok, Hits, #{answered, failed}}`, where every shard that did not answer is
  listed with its reason.
- The set of shards is macula's trust-checked provider list for
  `<org>/rag.query_shard_v1` (`macula:providers/4`), so only nodes the org
  delegated (D25) are asked. Each is called by node id (`macula:call/6` with
  `provider`).
- Embeddings: `configure/3` names this node's `model` and `dim`, summaries
  carry theirs, and a query asks only shards with the same embedding. Others
  are reported as `{embedding_mismatch, Theirs}`.
- A shard: `register_responder/1` answers the org's queries with a callback;
  `advertise/2` publishes this shard's summary and republishes it until
  `withdraw/0`. A hit's minimum is a binary `id` and a numeric `score`.
- `status/0`: whether this node's grant to provide the procedure is in place,
  with macula's reason when it is not, as mcl_om reports a provider grant. A
  refused grant is asked for again every `grant_retry_ms`.
- `shards/0`: the shards this node has a live summary from.
- The wire contract (`macula_rag_contract`), pinned by tests that read every
  payload back through macula's codec.
- CI: lint, EUnit, xref and Dialyzer on OTP 28.4.3; a tag-driven hex publish
  that refuses anything but the clean, pushed release tag and checks hex
  serves the tagged files.

### Not in this version

- The summary's bloom filter is carried but not used to choose shards.
