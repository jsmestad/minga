#!/bin/bash
set -euo pipefail

# Run mix test N times and count erl_child_setup errors, crashes, and failures.
RUNS=10
erl_errors=0
crashes=0
total_failures=0
total_duration=0

for i in $(seq 1 $RUNS); do
  start_time=$(date +%s)

  # Capture both stdout and stderr, don't fail on non-zero exit
  output=$(mix test --warnings-as-errors 2>&1 || true)

  end_time=$(date +%s)
  run_duration=$((end_time - start_time))
  total_duration=$((total_duration + run_duration))

  # Count erl_child_setup errors
  run_erl=$(echo "$output" | grep -c "erl_child_setup" || true)
  erl_errors=$((erl_errors + run_erl))

  # Count BEAM crashes
  run_crashes=$(echo "$output" | grep -c "Runtime terminating" || true)
  crashes=$((crashes + run_crashes))

  # Extract failure count from "N failures" line
  failure_line=$(echo "$output" | grep -oE '[0-9]+ failure' | head -1 || true)
  if [ -n "$failure_line" ]; then
    run_failures=$(echo "$failure_line" | grep -oE '[0-9]+')
    total_failures=$((total_failures + run_failures))
  fi
done

avg_duration=$((total_duration / RUNS))

echo "METRIC erl_errors=$erl_errors"
echo "METRIC test_failures=$total_failures"
echo "METRIC crashes=$crashes"
echo "METRIC avg_duration_s=$avg_duration"
