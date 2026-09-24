# macOS launched-app accessibility test

Run one command to verify Minga through XCTest's macOS accessibility snapshots and activation APIs, plus raw Accessibility attributes that XCTest does not expose:

```bash
scripts/test_macos_accessibility
```

The command builds an isolated Minga app with its embedded BEAM release, creates a temporary project and configuration, then runs the workflow once cold and once warm. The test opens synthetic Unicode fixtures, inspects two editor panes, activates a tab and pane through accessibility-resolved controls, filters and activates a nonselected picker result, dismisses a picker without activation, and verifies semantic identity, text, keyboard focus, insertion position, and a UTF-16 Unicode selection range. The workflow does not attach to or terminate a normal `com.minga.editor` app.

## Prerequisites

- macOS 15 or later with an interactive GUI login session
- the repository-pinned Erlang, Elixir, Zig, Go, and Xcode toolchains
- the XcodeGen version in `.xcodegen-version`
- macOS Accessibility permission for `MingaAccessibilityTests-Runner`, because XCTest does not expose selected-text range attributes

Install the pinned XcodeGen version when needed:

```bash
scripts/install_xcodegen "$TMPDIR/minga-xcodegen"
export PATH="$TMPDIR/minga-xcodegen:$PATH"
```

Xcode can ask you to authenticate to Enable UI Automation on the first run. Approve that request while the command is running. This enables XCTest interaction, but does not grant raw Accessibility access to the test runner.

The command prints an `Accessibility grant target` path after the build. To enable raw Accessibility access, open System Settings, select Privacy & Security, then Accessibility, click Add, and select `MingaAccessibilityTests-Runner.app` at that printed path. In the file chooser, press Command-Shift-G to enter the path. Turn on its switch and rerun the command if the first attempt has already exited. The local test waits up to 90 seconds for the grant; CI fails immediately when the grant is absent. macOS does not present a permission prompt for this runner, and the command never grants access or changes system security settings itself.

The build stays at `_build/macos-accessibility/DerivedData` so the runner has a stable path across runs. The runner is ad-hoc signed by the local Xcode build, so macOS may require a new grant after the test binary changes. A repeatable unattended CI lane needs a trusted macOS GUI runner with a stable signing identity and an approved Accessibility grant. GitHub's untrusted hosted macOS runner reports an infrastructure failure rather than passing or skipping this check.

## Isolation and cleanup

The runner gives the test app a dedicated bundle identifier, private `HOME` and XDG directories, a private native IPC parent, a fixture project, and an explicit config file. The UI test launches only that app identity. Success, assertion failure, application crash, and test timeout all terminate the owned app and remove the temporary fixture state. The runner also removes an orphaned embedded core whose executable path belongs to that exact test app bundle. DerivedData is a retained build artifact, not fixture state.

## Results and evidence

Exit status `0` means both the cold and warm workflows passed. Exit status `1` means the shipping accessibility behavior or the test build failed. Exit status `2` means a required macOS GUI, tool, XCTest UI-automation facility, or Accessibility permission was unavailable. A missing prerequisite is a failed validation run, not a skipped or passing test.

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
