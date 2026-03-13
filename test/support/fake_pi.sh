#!/bin/bash
# Fake pi process for PiRpc unit tests.
#
# Handles --version (returns 0.0.0-fake so version canary fires).
# In RPC mode, reads stdin forever and never writes to stdout,
# keeping the port alive so GenServer handle_call clauses can be tested.

if [[ "$1" == "--version" ]]; then
  echo "0.0.0-fake"
  exit 0
fi

while IFS= read -r line; do
  : # discard input
done
