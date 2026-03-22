#!/bin/bash
# Counts flaky timing patterns in test files.
# Excludes:
#   - Process.sleep(:infinity) / :timer.sleep(:infinity) — dummy process keepalive
#   - Lines that are comments
#   - eval_test.exs timeout-testing code
#   - agent_split_toggle_test.exs dummy process (:timer.sleep(1000))

set -euo pipefail

cd "$(dirname "$0")"

count=$(grep -rn 'Process\.sleep\|:timer\.sleep' test/ --include='*.exs' \
  | grep -v ':infinity' \
  | grep -v '#.*Process\.sleep\|#.*:timer\.sleep' \
  | grep -v 'eval_test.exs.*:timer.sleep(10_000)' \
  | grep -v 'agent_split_toggle_test.exs.*:timer.sleep(1000)' \
  | grep -v 'event_routing_test.exs.*:timer.sleep(:infinity)' \
  | grep -v 'native_test.exs.*Process\.sleep(100)' \
  | wc -l | tr -d ' ')

echo "METRIC flaky_patterns=$count"
echo ""
echo "Remaining flaky patterns:"
grep -rn 'Process\.sleep\|:timer\.sleep' test/ --include='*.exs' \
  | grep -v ':infinity' \
  | grep -v '#.*Process\.sleep\|#.*:timer\.sleep' \
  | grep -v 'eval_test.exs.*:timer.sleep(10_000)' \
  | grep -v 'agent_split_toggle_test.exs.*:timer.sleep(1000)' \
  | grep -v 'event_routing_test.exs.*:timer.sleep(:infinity)' \
  | grep -v 'native_test.exs.*Process\.sleep(100)' \
  || true
