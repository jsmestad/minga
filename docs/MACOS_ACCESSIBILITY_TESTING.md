# macOS launched-app accessibility test

Run one command to verify Minga through XCTest's supported macOS accessibility snapshots and activation APIs:

```bash
scripts/test_macos_accessibility
```

The command builds an isolated Minga app with its embedded BEAM release, creates a temporary project and configuration, then runs the workflow once cold and once warm. The test opens synthetic Unicode fixtures, inspects two editor panes, activates a tab and pane through accessibility-resolved controls, filters and activates a nonselected picker result, dismisses a picker without activation, and verifies semantic identity, text, and keyboard focus. Focused unit tests separately verify selected-text and insertion-range attributes. The workflow does not attach to or terminate a normal `com.minga.editor` app.

## Prerequisites

- macOS 15 or later with an interactive GUI login session
- the repository-pinned Erlang, Elixir, Zig, Go, and Xcode toolchains
- the XcodeGen version in `.xcodegen-version`

Install the pinned XcodeGen version when needed:

```bash
scripts/install_xcodegen "$TMPDIR/minga-xcodegen"
export PATH="$TMPDIR/minga-xcodegen:$PATH"
```

## Isolation and cleanup

The runner gives the test app a dedicated bundle identifier, private `HOME` and XDG directories, a private native IPC parent, a fixture project, and an explicit config file. The UI test launches only that app identity. Success, assertion failure, application crash, and test timeout all terminate the owned app and remove the temporary state. The runner also removes an orphaned embedded core whose executable path belongs to that exact temporary app bundle.

## Results and evidence

Exit status `0` means both the cold and warm workflows passed. Exit status `1` means the shipping accessibility behavior or the test build failed. Exit status `2` means a required macOS GUI, tool, or XCTest UI-automation facility was unavailable. A missing prerequisite is a failed validation run, not a skipped or passing test.

Evidence is retained at `_build/macos-accessibility/<UTC timestamp>-<pid>/`. Each attempted `cold` and `warm` directory contains the Xcode result bundle, the test log, and total runner timing. A run that reaches the test body attaches timings for each workflow operation to the result bundle. A failed workflow also attaches:

- the unmet condition
- a bounded XCTest accessibility-tree snapshot
- the application screenshot, when the app launched

The runner writes `infrastructure-failure.txt` beside the result bundle only when a GUI or UI-automation prerequisite is missing.

Set `MINGA_AX_ARTIFACT_ROOT` to retain evidence elsewhere:

```bash
MINGA_AX_ARTIFACT_ROOT="$PWD/accessibility-evidence" scripts/test_macos_accessibility
```

CI runs the same command in the `macOS Accessibility` job and uploads the evidence directory even when the workflow fails.
