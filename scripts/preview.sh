#!/bin/bash
# Renders a named SwiftUI chrome view, or every PreviewRegistry entry, to real PNG captures.
#
# Usage: scripts/preview.sh <ViewName>|--all
# Output: macos/Tests/Snapshots/<ViewName>.png (override PREVIEW_OUTPUT_DIR).
#
# CI can set PREVIEW_PROJECT_ROOT to a base checkout while using this driver's
# --all support. Both revisions still build and capture their own PreviewHost.

set -euo pipefail

VIEW_NAME="${1:?Usage: scripts/preview.sh <ViewName>|--all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${PREVIEW_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUTPUT_DIR="${PREVIEW_OUTPUT_DIR:-$PROJECT_ROOT/macos/Tests/Snapshots}"
BUILD_DIR="${PREVIEW_DERIVED_DATA:-$PROJECT_ROOT/macos/DerivedData/PreviewHost}"

if [ "$VIEW_NAME" = "--all" ]; then
    VIEW_NAMES="$(python3 "$SCRIPT_DIR/chrome_preview_evidence.py" names "$PROJECT_ROOT/macos/Sources/PreviewRegistry.swift")"
else
    VIEW_NAMES="$VIEW_NAME"
fi

cd "$PROJECT_ROOT"

# Ensure protocol opcodes are generated
if command -v mix >/dev/null 2>&1; then
    if ! mix protocol.gen 2>/dev/null; then
        echo "warning: mix protocol.gen failed; build may use stale opcodes" >&2
    fi
fi

# Regenerate Xcode project from project.yml
cd macos
xcodegen generate --quiet 2>/dev/null || xcodegen generate
cd "$PROJECT_ROOT"

# Build once, then launch a fresh process for each registered fixture.
xcodebuild build \
    -project macos/Minga.xcodeproj \
    -scheme PreviewHost \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet

APP_PATH="$BUILD_DIR/Build/Products/Debug/PreviewHost.app"

if [ ! -d "$APP_PATH" ]; then
    echo "error: PreviewHost.app not found at $APP_PATH" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Launch directly so PreviewSnapshotPolicy receives the same environment on both revisions.
while IFS= read -r name; do
    OUTPUT_PATH="$OUTPUT_DIR/$name.png"
    rm -f "$OUTPUT_PATH"
    PREVIEW_EAGER_LAYOUT=1 PREVIEW_VIEW="$name" PREVIEW_OUTPUT_DIR="$OUTPUT_DIR" "$APP_PATH/Contents/MacOS/PreviewHost"
    if [ ! -f "$OUTPUT_PATH" ]; then
        echo "error: screenshot not produced at $OUTPUT_PATH" >&2
        exit 1
    fi
    echo "$OUTPUT_PATH"
done <<< "$VIEW_NAMES"
