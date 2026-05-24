#!/usr/bin/env bash
# Generates a TUI snapshot PNG from a pre-recorded render command stream.
#
# Usage:
#   scripts/tui-snapshot.sh <snapshot_name> [--cols N] [--rows N] [--font NAME] [--size N]
#
# The script:
#   1. Builds minga-snapshot (if needed)
#   2. Pipes the fixture at zig/tests/fixtures/<name>.bin through minga-snapshot
#   3. Writes the output PNG to zig/tests/snapshots/<name>.png
#
# Prerequisites:
#   - macOS (CoreText is required for font rasterization)
#   - Zig 0.16+ installed
#   - Fixtures generated via: mix run scripts/generate_snapshot_fixtures.exs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG_DIR="$REPO_ROOT/zig"
FIXTURES_DIR="$ZIG_DIR/tests/fixtures"
SNAPSHOTS_DIR="$ZIG_DIR/tests/snapshots"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <snapshot_name> [--cols N] [--rows N] [--font NAME] [--size N]"
    echo ""
    echo "Available fixtures:"
    ls "$FIXTURES_DIR"/*.bin 2>/dev/null | xargs -I{} basename {} .bin || echo "  (none, run: mix run scripts/generate_snapshot_fixtures.exs)"
    exit 1
fi

NAME="$1"
shift
FIXTURE="$FIXTURES_DIR/$NAME.bin"

if [ ! -f "$FIXTURE" ]; then
    echo "error: fixture not found: $FIXTURE"
    echo "Run: mix run scripts/generate_snapshot_fixtures.exs"
    exit 1
fi

mkdir -p "$SNAPSHOTS_DIR"

# Build minga-snapshot
echo "Building minga-snapshot..."
cd "$ZIG_DIR"
zig build 2>&1

SNAPSHOT_BIN="$ZIG_DIR/zig-out/bin/minga-snapshot"
if [ ! -x "$SNAPSHOT_BIN" ]; then
    echo "error: minga-snapshot binary not found at $SNAPSHOT_BIN"
    echo "This tool requires macOS (CoreText font rasterization)."
    exit 1
fi

OUTPUT="$SNAPSHOTS_DIR/$NAME.png"

echo "Generating snapshot: $NAME"
cat "$FIXTURE" | "$SNAPSHOT_BIN" --output "$OUTPUT" "$@"

echo "Output: $OUTPUT"
