#!/bin/bash
# Counts test files with async: false (lower is better).
set -uo pipefail

cd "$(dirname "$0")"

count=$(grep -rl "async: false" test/ --include='*.exs' | grep -v _build | wc -l | tr -d ' ')

echo "METRIC async_false_count=$count"
