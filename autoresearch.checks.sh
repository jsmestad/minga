#!/bin/bash
set -euo pipefail
# Single test run must pass with 0 failures
mix test --warnings-as-errors
