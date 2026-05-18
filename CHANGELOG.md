# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial scaffold: protocol module, advertiser, responder, router,
  facade, supervisor tree.
- Documented federation design in `guides/federation_design.md`.
- Common Test smoke suite.

### Planned
- Wire `macula_rag_advertiser` into the `_mesh.bloom` advertisement
  channel via `macula:publish/4`
- Wire `macula_rag_responder` as a `macula:advertise/3` RPC handler
- Implement `macula_rag_router` peer selection from Bloom summaries
- Add quorum / TTL / hedged-request policies

## [0.1.0] - YYYY-MM-DD

_Not yet released._
