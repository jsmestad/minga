#!/usr/bin/env bash
set -euo pipefail
export MIX_ENV=test
mix compile --warnings-as-errors >/dev/null
mix test.llm test/minga/telemetry_test.exs test/minga/telemetry/integration_test.exs test/minga_editor/render_pipeline_test.exs >/tmp/minga-autoresearch-checks.log 2>&1 || { tail -80 /tmp/minga-autoresearch-checks.log; exit 1; }
