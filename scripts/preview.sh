#!/bin/bash
# Renders a single SwiftUI chrome view to a PNG screenshot.
#
# Usage: scripts/preview.sh <ViewName>
#
# Available views: GitStatusView, FileTreeView, CompletionOverlay,
#                  StatusBarView, TabBarView, NotificationCenterView
#
# The script builds the PreviewHost target (fast: no Metal, no BEAM),
# launches it with the view name, and the app self-captures its window
# to a PNG before exiting.
#
# Output: macos/Tests/Snapshots/<ViewName>.png

set -euo pipefail

VIEW_NAME="${1:?Usage: scripts/preview.sh <ViewName>}"
OUTPUT_DIR="macos/Tests/Snapshots"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# Ensure protocol opcodes are generated
if command -v mix >/dev/null 2>&1; then
    mix protocol.gen 2>/dev/null || true
fi

# Regenerate Xcode project from project.yml
cd macos
xcodegen generate --quiet 2>/dev/null || xcodegen generate
cd "$PROJECT_ROOT"

# Build PreviewHost (no Metal renderer, no BEAM, fast)
xcodebuild build \
    -project macos/Minga.xcodeproj \
    -scheme PreviewHost \
    -configuration Debug \
    -quiet \
    2>&1 | grep -v "^$" || true

# Find the built app
BUILD_DIR=$(xcodebuild -project macos/Minga.xcodeproj -scheme PreviewHost -configuration Debug -showBuildSettings 2>/dev/null | grep "^\s*BUILT_PRODUCTS_DIR = " | sed 's/.*= //')
APP_PATH="$BUILD_DIR/PreviewHost.app"

if [ ! -d "$APP_PATH" ]; then
    echo "error: PreviewHost.app not found at $APP_PATH" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Launch directly (not via `open`) so environment variables reach the process.
# The app self-captures its window and exits.
PREVIEW_VIEW="$VIEW_NAME" PREVIEW_OUTPUT_DIR="$OUTPUT_DIR" "$APP_PATH/Contents/MacOS/PreviewHost" 2>/dev/null || true

OUTPUT_PATH="$OUTPUT_DIR/${VIEW_NAME}.png"

if [ -f "$OUTPUT_PATH" ]; then
    echo "$OUTPUT_PATH"
else
    echo "error: screenshot not produced at $OUTPUT_PATH" >&2
    exit 1
fi
