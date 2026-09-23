# Contributing

Trunk-based. Commit directly to `main`. No PRs.

## Build

```bash
scripts/check.sh    # compile, eunit, lint, xref, dialyzer, on the pinned OTP
```

## Style

- Erlang: `warnings_as_errors`, dialyzer clean
- Vertical slicing only — no `services/`, no `helpers/`

## Issues

https://github.com/macula-io/macula-rag/issues
