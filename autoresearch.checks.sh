#!/bin/bash
# Verify changed test files still pass (run 3x for flake detection)
set -euo pipefail

cd "$(dirname "$0")"

changed_tests=$(git diff --name-only main -- 'test/**/*_test.exs' 2>/dev/null || true)

if [ -z "$changed_tests" ]; then
  echo "No test files changed, skipping checks"
  exit 0
fi

echo "Running changed tests 3x for flake detection:"
echo "$changed_tests"

for run in 1 2 3; do
  echo ""
  echo "=== Run $run/3 ==="
  # shellcheck disable=SC2086
  MIX_ENV=test mix test --warnings-as-errors $changed_tests
done

echo ""
echo "All 3 runs passed!"
