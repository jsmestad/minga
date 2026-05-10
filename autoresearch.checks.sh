#!/usr/bin/env bash
set -euo pipefail
./autoresearch.sh >/tmp/minga-tree-sitter-highlight-bench-check.log
mix zig.lint >/tmp/minga-zig-lint-check.log 2>&1 || { tail -80 /tmp/minga-zig-lint-check.log; exit 1; }
