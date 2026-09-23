#!/usr/bin/env bash
# Run what CI runs: compile (warnings_as_errors), eunit, lint, xref, dialyzer,
# on the OTP pinned in .tool-versions, first on PATH, and say which.
set -euo pipefail
cd "$(dirname "$0")/.."
OTP="$(awk '/^erlang/ {print $2}' .tool-versions)"
export PATH="$HOME/.local/share/mise/installs/erlang/${OTP}/bin:$PATH"
echo "OTP $(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().') (pinned ${OTP})"
rebar3 compile
rebar3 eunit
rebar3 lint
rebar3 xref
rebar3 dialyzer
