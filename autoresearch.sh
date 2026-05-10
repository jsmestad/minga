#!/usr/bin/env bash
set -euo pipefail
export MIX_ENV=test
mix compile --warnings-as-errors >/dev/null
mix run bench/key_latency_bench.exs
