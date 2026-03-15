# Autoresearch: Fix erl_child_setup Flakiness

## Objective

Eliminate `erl_child_setup: failed with error 32 on line 284` errors and related BEAM crashes during `mix test`. Error 32 is EPIPE, which happens when the BEAM's child setup process can't spawn OS processes fast enough. With 282 async test modules, many calling `System.cmd("git", ...)` or `Port.open`, the concurrent process spawn pressure overwhelms `erl_child_setup`.

## Metrics

- **Primary**: `erl_errors` (count across 10 test runs, lower is better)
- **Secondary**: `test_failures` (non-flaky failures), `crashes` (full BEAM crashes), `avg_duration_s` (mean run time)

## How to Run

`./autoresearch.sh` outputs `METRIC name=number` lines.

## Root Cause

The BEAM uses `erl_child_setup` to spawn OS processes. When hundreds of async tests simultaneously call `System.cmd("git", ...)`, the pipe between the BEAM and `erl_child_setup` can break (EPIPE). This manifests as either a warning printed to stderr or a full BEAM crash.

Key OS-process-spawning test files (all async: true):
- `test/minga/file_find_test.exs` (git init, git add)
- `test/minga/file_tree/git_status_test.exs` (git status)
- `test/minga/extension/git_test.exs` (git init, clone, add, commit, push)
- `test/minga/extension/updater_test.exs` (git init, clone, add, commit, push)
- `test/minga/agent/tools/git_test.exs`

Production code that spawns OS processes during tests:
- `Minga.Git.root_for/1` calls `System.cmd("git", ["rev-parse", ...])`
- `Minga.Git.show_head/2` calls `System.cmd("git", ["show", ...])`
- `Minga.Git.Tracker` starts `Git.Buffer` which calls `Git.show_head` in `init/1`
- `Minga.Clipboard.System` calls `System.cmd` for clipboard access
- `Minga.FileFind` calls `System.cmd("fd"/"git"/"find", ...)`

## Files in Scope

Tests that spawn OS processes:
- `test/minga/file_find_test.exs`
- `test/minga/file_tree/git_status_test.exs`
- `test/minga/extension/git_test.exs`
- `test/minga/extension/updater_test.exs`
- `test/minga/agent/tools/git_test.exs`
- `test/minga/integration/minga_org_test.exs`
- `test/minga/git_test.exs`
- `test/minga/git/tracker_test.exs`

Test infrastructure:
- `test/test_helper.exs`

## Off Limits

- Do not change application/production code behavior
- Do not remove or skip tests
- Do not change test assertions or expected behavior

## Constraints

- `mix test --warnings-as-errors` must pass (0 failures, 0 warnings)
- All existing tests must still run and pass
- Fix flakiness by reducing concurrent OS process pressure, not by hiding errors
- Acceptable approaches: marking OS-heavy test modules as `async: false`, batching git operations in test setups, using temp dirs more carefully

## What's Been Tried

### Git.Backend DI (major win)
Extracted `Minga.Git` into a delegator + `Git.Backend` behaviour + `Git.System` (production) + `Git.Stub` (test). All callers of `Minga.Git` now go through the configurable backend. In tests, the ETS-backed `Git.Stub` returns canned data without spawning OS processes. This eliminated the biggest source of concurrent subprocess spawning.

### FileTree.GitStatus refactor
Replaced raw `System.cmd("git", ["status", ...])` in `FileTree.GitStatus` with `Minga.Git.status/1` (goes through backend). Removed duplicate porcelain parsing code.

### Clipboard buffer-local DI
`EditorCase.start_editor` now injects `clipboard: :none` directly on the buffer via `BufferServer.set_option`. This prevents the Mox `UnexpectedCallError` that occurred when `Options.reset()` in one test leaked `:unnamedplus` into another test's Editor process.

### Extension test restructuring
Split `Extension.GitTest` into pure unit tests (async: true) and integration tests that spawn real git (async: false). Tests were previously deleted; reviewer caught it and they were restored.

### Dead ends
- `max_cases: 4` eliminated failures but slowed tests by 45%. Not worth it.
- Marking `file_find_test` and `project_search_test` as `async: false` was rejected as a workaround; their OS process spawning is marginal (~10 calls total).
