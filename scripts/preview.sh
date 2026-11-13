#!/bin/bash
# Existing PreviewHost transport, with a whole-run deadline and capture receipts.
# Usage: scripts/preview.sh <ViewName>|--all|--agent-workspace [--wall-timeout 600]
# PREVIEW_OUTPUT_DIR and PREVIEW_DERIVED_DATA select isolated artifact/build roots.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/preview_capture.py" "$@"
