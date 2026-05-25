#!/usr/bin/env bash
# Generates a TUI snapshot PNG from a pre-recorded render command stream.
#
# Usage:
#   scripts/tui-snapshot.sh <snapshot_name> [--cols N] [--rows N] [--font NAME_OR_PATH] [--size N]
#
# The script:
#   1. Builds minga-snapshot (if needed)
#   2. Pipes the fixture at zig/tests/fixtures/<name>.bin through minga-snapshot
#   3. Writes the output PNG to zig/tests/snapshots/<name>.png
#
# Prerequisites:
#   - macOS or Linux
#   - Zig 0.16+ installed
#   - Linux only: pkg-config and freetype2 development files
#   - Fixtures generated via: mix run scripts/generate_snapshot_fixtures.exs

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG_DIR="$REPO_ROOT/zig"
FIXTURES_DIR="$ZIG_DIR/tests/fixtures"
SNAPSHOTS_DIR="$ZIG_DIR/tests/snapshots"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <snapshot_name> [--cols N] [--rows N] [--font NAME_OR_PATH] [--size N]"
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

OS_NAME="$(uname -s)"
case "$OS_NAME" in
    Darwin)
        ;;
    Linux)
        if ! command -v pkg-config >/dev/null 2>&1; then
            echo "error: pkg-config is required for Linux TUI snapshots"
            echo "Install pkg-config and freetype2 development files, then retry."
            exit 1
        fi
        if ! pkg-config --exists freetype2; then
            echo "error: freetype2 development files are required for Linux TUI snapshots"
            echo "Install freetype2 via your package manager, then retry."
            exit 1
        fi
        ;;
    *)
        echo "error: TUI snapshots are supported on macOS and Linux only (found $OS_NAME)"
        exit 1
        ;;
esac

# Build minga-snapshot
echo "Building minga-snapshot..."
cd "$ZIG_DIR"
zig build -Dsnapshot=true 2>&1

SNAPSHOT_BIN="$ZIG_DIR/zig-out/bin/minga-snapshot"
if [ ! -x "$SNAPSHOT_BIN" ]; then
    echo "error: minga-snapshot binary not found at $SNAPSHOT_BIN"
    echo "This tool requires macOS or Linux with freetype2 development files."
    exit 1
fi

OUTPUT="$SNAPSHOTS_DIR/$NAME.png"

echo "Generating snapshot: $NAME"
cat "$FIXTURE" | "$SNAPSHOT_BIN" --output "$OUTPUT" "$@"

echo "Output: $OUTPUT"
