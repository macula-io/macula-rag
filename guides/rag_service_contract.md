# The RAG service contract

This exists so anyone can serve a corpus on the Macula mesh that any caller can query, and
check, without asking anyone.

This guide is the canonical text. `macula_rag_corpus` (through the `macula_rag` facade) is its
Erlang implementation, and `test/vectors/` holds the vectors below as files. mcl-rag
(`macula-services/mcl-rag`) is the reference provider. There is no central registry: a caller
finds providers in the realms it trusts and decides for itself which corpus to believe.

## The procedures

A provider serves them under its own org, `<org>/<name>`, version 1, with the realm's grant for
each:

| Procedure | Arguments | Reply |
|---|---|---|
| `describe_corpus` | none | `corpus_hash`, `model`, `dim`, `repos` (`id`, `url`, `branch`, `commit`); optionally `signature` and `signed_by` |
| `answer_query` | `query_text` or `query_vector`, `top_k` 1..100 (default 10), `topics` (optional) | `corpus_hash`, `hits` |
| `get_chunk_by_id` | `chunk_id` | a hit without `score` |
| `get_document_verbatim` | `source_path` | `source_path`, `raw_bytes`, `provenance` |
| `list_sources_page` | `offset`, `limit` (at most 200) | rows with `source_path` and `provenance` |

A **hit** is at least `chunk_id`, `score`, `content` and `provenance`. A provider may add more.

A `query_vector` must be in the provider's embedding, as `describe_corpus` names it. One of
another length is refused (`dimension_mismatch`). The role prefix belongs to the model (e5:
`query: ` before the text).

## Provenance

| Field | Meaning |
|---|---|
| `kind` | `corpus` (from a listed repo) or `deposit` (anything else) |
| `path` | where the text sits: `<repo_id>/<path in repo>` for corpus content |
| `repo_id`, `commit` | corpus only: the repo and the 40-hex commit the text was ingested at |
| `start_line`, `end_line` | a chunk's lines |
| `content_sha256` | lowercase hex sha256 of the text returned (a chunk's content, a document's bytes) |
| `deposited_by` | a deposit's depositor, as a hex node id, when known |

A corpus file unchanged across a pin move keeps the commit it was ingested at, since its bytes
are the same at the new pin.

`macula_rag:verify_hit/1` checks a hit's text against its `content_sha256`. It says nothing
about whether the repo and commit are true; that is what the corpus hash and signature are for.

## The corpus hash

`corpus_hash` is the lowercase hex sha256 of the RFC 8785 (JCS) canonical JSON of

```json
{"dim": <dim>, "model": "<model>", "repos": [{"branch", "commit", "id", "url"}, ...]}
```

with the repos in the provider's list order. The model and dim are in it because the same repos
embedded differently are a different corpus. Every `answer_query` reply names it, so a caller can
tell which corpus answered and recompute the hash from `describe_corpus`.

A provider with no corpus list describes an empty corpus (`"repos": []`), which still has a hash.

## The operator's signature

A signature is optional. When present, `signature` is a macula signed object
(`macula_signed_object`, CBOR bytes on the wire, carrying its key) over the single field
`corpus_hash` (text), under the label `macula-rag corpus v1`. `signed_by` is the hex node id of
that key. It is a **display label and never evidence**.

The object is static, so any provider can serve a copy. A caller counts a corpus as **signed by
node P** only when all of these hold:

1. it called P itself, with `macula:call/6` and `#{provider => P}`, P taken from
   `macula:providers/3`. A `macula:call/5` caller does not know who answered, so it treats the
   corpus as unsigned;
2. the described repos, model and dim hash to the described `corpus_hash`;
3. the object verifies under the label and the caller's profile;
4. the node id derived from the key the verification returns is P;
5. the signed `corpus_hash` is the one the caller recomputed.

`macula_rag:verify_corpus(Description, P, Profile)` is exactly this check (2 to 5). It returns
`{ok, {signed, P}}`, `{ok, unsigned}` or the reason it refused: `malformed_description`,
`corpus_hash_mismatch`, `{signature, Reason}`, `signer_not_provider` or
`signature_hash_mismatch`. A signature says P vouched for that corpus; it does not say when.

## Vectors

**Label.** `macula-rag corpus v1`, hex `6d6163756c612d72616720636f72707573207631`.

**Canonical JSON.** The input

```json
{"b": {"c": "q\"b\\s\n\u0001é/"}, "a": [1, "x"]}
```

is, canonically,

```json
{"a":[1,"x"],"b":{"c":"q\"b\\s\n\u0001é/"}}
```

**Corpus hash.** The description

```json
{
  "model": "macula/multilingual-e5-small:f16",
  "dim": 384,
  "repos": [
    {
      "id": "alpha",
      "url": "https://example.org/alpha.git",
      "branch": "main",
      "commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    {
      "id": "beta",
      "url": "/srv/mirrors/beta.git",
      "branch": "trunk",
      "commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
  ]
}
```

has `corpus_hash` `0d5f037bfa41e1bce262d87098576102063fa084f63441a348d2a7648b4b2644`.

**Signed corpus.** `test/vectors/signed_corpus.json` holds that corpus hash signed once per
profile with a synthetic key (made by `scripts/make_signed_corpus_vectors.escript`, which uses
macula alone): `profile`, `signed_by` and `signature_base64`. Each verifies as
`{signed, signed_by}` under its own profile, and is refused for any other pinned provider.

| Profile | signed_by |
|---|---|
| `pq_pure` | `6b831983524523058683796c1055f122a2e767794a73bba41410e61a19e1f14b` |
| `pq_hybrid` | `2b87c4c0732ddb499bac7b6d8c4a611de31a4d338ba51f7665e04300f733689d` |
