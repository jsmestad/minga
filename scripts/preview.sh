#!/bin/bash
# Renders a single SwiftUI chrome view to a PNG screenshot.
#
# Usage: scripts/preview.sh <ViewName>
#
# Available views: EditorChromeView, AgentChromeView, GitStatusView,
#                  GitStatusClean, GitStatusConflict, GitStatusDense,
#                  FileTreeView, FileTreeEmpty, FileTreeError, FileTreeDeep,
#                  CompletionOverlay, StatusBarView, TabBarView,
#                  NotificationCenterView, NotificationStack, BottomPanelView,
#                  BottomPanelEmpty, SettingsView, ToolManagerView,
#                  ObservatoryView, AgentChatView,
#                  AgentChatStreaming, AgentChatApproval, AgentChatError,
#                  AgentChatCompletion, AgentChatSummary, BoardView,
#                  ChangeSummaryView, DispatchSheetView,
#                  PickerOverlay, MinibufferView, WhichKeyOverlay, SearchToolbar,
#                  HoverPopupOverlay, SignatureHelpOverlay, DiagnosticsEditorView,
#                  TabBarOverflow
#
# The script builds the PreviewHost target, launches it with the view name,
# and the app self-captures its window to a PNG before exiting. Full-shell
# previews exercise the real editor renderer path without starting the BEAM.
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
    if ! mix protocol.gen 2>/dev/null; then
        echo "warning: mix protocol.gen failed; build may use stale opcodes" >&2
    fi
fi

# Regenerate Xcode project from project.yml
cd macos
xcodegen generate --quiet 2>/dev/null || xcodegen generate
cd "$PROJECT_ROOT"

# Build PreviewHost.
xcodebuild build \
    -project macos/Minga.xcodeproj \
    -scheme PreviewHost \
    -configuration Debug \
    -quiet \
    2>&1 | grep -v "^$"

# Find the built app
BUILD_DIR=$(xcodebuild -project macos/Minga.xcodeproj -scheme PreviewHost -configuration Debug -showBuildSettings 2>/dev/null | grep "^\s*BUILT_PRODUCTS_DIR = " | sed 's/.*= //')
APP_PATH="$BUILD_DIR/PreviewHost.app"

if [ ! -d "$APP_PATH" ]; then
    echo "error: PreviewHost.app not found at $APP_PATH" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Launch directly (not via `open`) so environment variables reach the process.
# PreviewSnapshotPolicy is the source of truth for which view names may use eager layout.
PREVIEW_EAGER_LAYOUT=1 PREVIEW_VIEW="$VIEW_NAME" PREVIEW_OUTPUT_DIR="$OUTPUT_DIR" "$APP_PATH/Contents/MacOS/PreviewHost"

OUTPUT_PATH="$OUTPUT_DIR/${VIEW_NAME}.png"

if [ -f "$OUTPUT_PATH" ]; then
    echo "$OUTPUT_PATH"
else
    echo "error: screenshot not produced at $OUTPUT_PATH" >&2
    exit 1
fi
