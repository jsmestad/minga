#!/usr/bin/env bash
set -euo pipefail
MIX_ENV=test mix test.llm test/minga_editor/render_pipeline test/minga_editor/frontend test/minga_editor/shell 2>/tmp/minga-render-check.err || { cat /tmp/minga-render-check.err; exit 1; }
