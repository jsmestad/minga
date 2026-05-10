#!/usr/bin/env bash
set -euo pipefail
./autoresearch.sh >/tmp/minga-swift-render-bench-check.log
mix swift.harness >/tmp/minga-swift-harness-check.log 2>&1 || { tail -80 /tmp/minga-swift-harness-check.log; exit 1; }
