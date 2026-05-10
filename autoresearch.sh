#!/usr/bin/env bash
set -euo pipefail
MIX_ENV=test mix run bench/key_latency_bench.exs
