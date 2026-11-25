# Contributing to Minga

Thanks for your interest! Minga is in early development and contributions are welcome, whether that's bug reports, feature ideas, or code.

## Build from source

Minga combines an Elixir/BEAM core with a Swift/Metal macOS GUI, a Go/Bubble Tea terminal renderer, and Zig native binaries (tree-sitter parser and process helpers). Install the pinned toolchains from `.tool-versions` with [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/):

### Install the toolchain

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add golang
asdf plugin add zig
```

### Clone and build

```bash
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install          # Installs pinned Erlang, Elixir, Go, and Zig from .tool-versions
mix deps.get
mix compile           # Compiles Elixir and the Go terminal renderer
make native.support   # Builds the Zig tree-sitter parser and helper binaries
```

The first build takes a few minutes while Zig compiles 50 tree-sitter grammars. After that, rebuilds are incremental and fast.

### Refresh generated sources

Run `mix codegen` after changing `docs/protocol_schema.toml`, `config/language_aliases.json`, or either generator. Commit the refreshed Elixir and Go files and the Zig export block if they changed. Swift and Zig build inputs remain ignored. CI regenerates the sources on a clean checkout and rejects any tracked changes, missing generated files, or obsolete files in `generated/elixir/`. Ordinary `mix compile` reads the checked-in Elixir files without running either generator.

### Run it

```bash
bin/minga              # Empty buffer
bin/minga path/to/file # Open a file
```

Source launchers require Python 3 and keep Minga runtime state in `.minga-dev/profile` in the current worktree. This includes Minga config, extensions, history, sessions, and credentials. They do not import the installed app's profile or provider environment variables.

By default the launch also sets `HOME` to a private directory in that profile. Claude Code keeps its `claude auth login` sign-in in the macOS login keychain, and the keychain is not reachable from that `HOME`, so the Claude bridge reports that Claude Code is not signed in. To verify the bridge or another keychain-backed tool from source, launch with `MINGA_DEV_REAL_HOME=1`, for example `MINGA_DEV_REAL_HOME=1 bin/minga-mac`. This keeps your real `HOME` for Minga and its child processes. Minga's own config, data, cache, and state still use the profile's `XDG_*` directories, and `TMPDIR` stays private. Any other value, or no value, keeps `HOME` isolated. Tools that write under `HOME` instead of XDG directories write to your real home in this mode.

Quit the source editor and run `make clean` to delete that profile. The next launch starts with defaults. This command does not remove build outputs, dependencies, project files, or the installed app's profile. It refuses while a source editor is using the profile.

For a one-off source smoke run that should not use the worktree profile, run `python3 scripts/dev_profile.py fresh minga path/to/file`. The launcher removes that temporary profile when the editor exits. For restart testing, use the persistent profile in a disposable worktree instead.

## Running Tests

```bash
mix test.llm                   # Non-heavy Elixir suite (LLM-friendly summary)
cd go/tui && go test ./...     # Go/Bubble Tea terminal renderer tests
cd zig && zig build test       # Zig parser and helper tests
```

### Native macOS unit tests

After generating the Xcode project (`cd macos && xcodegen generate`), run `scripts/test_macos_unit` from the repository root. This is the authoritative Xcode/Metal unit-test entrypoint used by CI and the Swift stage of `make done`; SwiftPM is not a substitute for this native gate.

Scheme `MingaUnitTests` builds the existing `MingaTests` target for two execution contexts, without changing its source ownership. Production `Minga.app` builds separately and must never host or embed the unit tests. Production-app probes receive its explicit path through the scheme's `MINGA_TEST_PRODUCTION_APP_PATH` environment variable. The host compiles the existing production Metal shader so `Bundle.main` retains real shader-library coverage.

The entrypoint runs ordinary tests bare with explicit empty `TEST_HOST` and `BUNDLE_LOADER` build settings, excluding the two focus suites. It then runs an explicit hosted `build-for-testing` phase, verifies the fresh plan and products, and executes all 13 `EditorFocusPolicyTests` functions from a pinned policy copy. Only accepted policy execution authorizes `FocusReplayWindowTests` in a separate host process from a replay copy of that same input. Both plan copies bind their original product root, select their own suite explicitly, and remove conflicting target-local skip filters. These exclusions route tests between execution contexts; they do not omit acceptance coverage.

Production-window replay observes responder and positive AX identity within the same bounded wait; observation never assigns focus or substitutes an expected AX object. For native fields, AX identity means the exact AppKit cell installed on the expected production field, with the cell's `controlView` pointing back to that field. CI repeats the canonical lifecycle against the same DerivedData and retains a separate warm manifest, so hosted-to-bare reuse is exercised rather than inferred from a cache. Do not combine the focus selectors or run competing GUI tests concurrently: suite-local `.serialized` does not isolate application activation and key-window state from other suites.

Use `--output-dir PATH` to retain evidence elsewhere (default: `macos-unit-evidence/`). Each invocation preserves separate action logs and `.xcresult` bundles, and writes `results.json` with the three actual result summaries/test trees, commands, exit statuses, timings, and aggregate logical-function counts. Global xcresult counts do not count parameterized executions; replay acceptance requires the enumerator and all seven actual named passed argument nodes. Evidence includes settings queried from the testing build graph, actual bare/hosted runtime identity, the hosted build command/status/log, and raw pre/post plan signatures and copies. For this scheme, the pinned Xcode emits format 1 with a top-level `MingaTests` target and an application-bundle `TestHostPath`; unsupported formats fail explicitly. The default build graph omits the test target, and `test` alone does not produce the persisted plan required for replay. Failed builds and missing, ambiguous, stale, or wrong-mode hosted plans block focused execution rather than fall back to cached products. Any ordinary failure remains an aggregate failure even if subsequent hosted diagnostics pass. Missing results, zero executed tests, incomplete focus coverage, or missing or reused focus test-runner PIDs fail the gate even if `xcodebuild` exits zero. The empty-setting transition and warm hosted-to-bare reuse require actual macOS verification; command flags alone are not native proof.

## Before Committing

Run `make done` (or `make lint` for fast lint only) before requesting review. CI owns the full gate; `make lint.full` exists for reproducing a CI failure locally.

```bash
make lint                         # Formatting + changed Credo + ExDNA, in parallel with compile -> incremental Dialyzer + Reach arch policy (~25s warm)
make done                         # Fast lint + mix test.llm + site/macOS gates when relevant files changed
make lint.full                    # Same plus full Credo, Reach smells, and classic Dialyzer (minutes)
mix test.llm                      # Non-heavy test suite with an LLM-friendly summary
```

Both gates run every independent check even when one fails (Dialyzer and Reach are skipped only when compile fails) and print one status line per check followed by the logs of the failed ones. The fast gate skips compile, Dialyzer, Reach, and ExDNA on branches with no Elixir-relevant change; `site/`-only branches skip Elixir and Swift checks and run site bundle and link checks instead. CI also runs full Credo, ExDNA, Reach architecture checks, and classic Dialyzer before merge.

The [Reach smells workflow](https://github.com/jsmestad/minga/blob/main/.github/workflows/reach-smells.yml) reports advisory findings weekly or on demand. It does not block PRs. The required `Swift (macOS GUI)` check passes only when both the macOS correctness and performance jobs pass.

Swift correctness CI restores only Xcode's compilation cache. It builds fresh app and test bundles and records native build and test time separately in `macos-unit-evidence/results.json`. The [scheduled Swift evidence workflow](https://github.com/jsmestad/minga/blob/main/.github/workflows/swift-evidence.yml) still starts with a cold build.

## Project Layout

See `AGENTS.md` (in the repo root) for the full project structure, coding standards, and conventions. The highlights:

- **`@spec` on every public function**: Elixir 1.20's type system is strict
- **Pattern matching over `if`/`cond`**: multi-clause functions preferred
- **Test files mirror `lib/`**: `lib/minga/buffer/document.ex` → `test/minga/buffer/document_test.exs`
- **Property-based tests** with StreamData for data structures

## Key Documentation

| Doc | What it covers |
|-----|---------------|
| [README.md](README.md) | Project overview and quick start |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Supervision tree, layer rules, and rendering pipeline |
| [docs/AUTOMATION-IPC.md](docs/AUTOMATION-IPC.md) | Native macOS `minga-ipc` readiness and navigation receipts |
| [docs/MACOS_ACCESSIBILITY_TESTING.md](https://github.com/jsmestad/minga/blob/main/docs/MACOS_ACCESSIBILITY_TESTING.md) | Real launched-app macOS accessibility validation |
| [docs/SNAPSHOT_TESTING.md](docs/SNAPSHOT_TESTING.md) | Screen snapshot tests: what they catch, the file format, and how to write one |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Rendering performance gates and how to read them |
| [docs/RELEASING.md](docs/RELEASING.md) | Preparing, verifying and publishing builds and the site |
| `AGENTS.md` | Coding standards, project structure, how to add features |

## How to Add Things

Step-by-step recipes live under `docs/recipes/`:

- **New command:** [docs/recipes/new-command.md](https://github.com/jsmestad/minga/blob/main/docs/recipes/new-command.md)
- **New motion:** [docs/recipes/new-motion.md](https://github.com/jsmestad/minga/blob/main/docs/recipes/new-motion.md)
- **New text object:** [docs/recipes/new-text-object.md](https://github.com/jsmestad/minga/blob/main/docs/recipes/new-text-object.md)
- **New or modified agent tool:** [docs/recipes/new-agent-tool.md](https://github.com/jsmestad/minga/blob/main/docs/recipes/new-agent-tool.md)
- **New render command:** [docs/recipes/new-render-command.md](https://github.com/jsmestad/minga/blob/main/docs/recipes/new-render-command.md)
- **New tree-sitter grammar:** [docs/recipes/new-grammar.md](https://github.com/jsmestad/minga/blob/main/docs/recipes/new-grammar.md)
- **Update screen snapshots:** [docs/recipes/update-snapshots.md](https://github.com/jsmestad/minga/blob/main/docs/recipes/update-snapshots.md)

## Performance Debugging with Telemetry

Minga instruments the keystroke-to-render critical path with `:telemetry` spans. Set `:log_level_render` to `:debug` in your config to see per-stage timing in `*Messages*` (press `SPC b m` to view):

```elixir
# In ~/.config/minga/config.exs
set :log_level_render, :debug
```

This shows output like:

```
[render:layout] 12µs
[render:scroll] 45µs
[render:content] 89µs
[render:agent_content] 4µs
[render:chrome] 34µs
[render:compose] 18µs
[render:emit] 22µs
[render:total] 224µs
[input:dispatch] 312µs
[command:move_down] 8µs
[port:emit] 48µs (1234 bytes)
```

### Available telemetry events

| Event | Metadata | What it measures |
|-------|----------|------------------|
| `[:minga, :render, :pipeline]` | `window_count` | Full render frame |
| `[:minga, :render, :stage]` | `stage` atom | Individual render stage |
| `[:minga, :input, :dispatch]` | | Keystroke through input router |
| `[:minga, :command, :execute]` | `command` atom | Named command execution |
| `[:minga, :port, :emit]` | `byte_count` | Protocol encoding + port write |
| `[:minga, :swap, :write]` | `stage` atom (`snapshot`, `prepare`, `publish`), `byte_count` on `prepare` | One stage of a buffer's swap file write |

### Attaching custom handlers

For deeper analysis (histograms, percentile tracking), attach your own handler in IEx or a config file:

```elixir
:telemetry.attach("my-handler", [:minga, :render, :pipeline, :stop], fn _event, measurements, metadata, _config ->
  duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)
  IO.puts("Frame: #{duration_us}µs, windows: #{metadata.window_count}")
end, nil)
```

### Running the overhead benchmark

To verify telemetry overhead is negligible:

```bash
mix run benchmarks/telemetry_overhead.exs
```

## Collecting stale-intent session evidence

The shared runtime log can contain warnings from both normal editor use and tests. It cannot establish per-session rejection rates by itself. For [#3513](https://github.com/jsmestad/minga/issues/3513), `scripts/collect_rejection_sessions.py` brackets one operator-confirmed session, retains its dedicated debug log and canonical-log byte interval, and reports rejections by surface, generation, and reason. The collector owns evidence, not native app lifecycle.

Use a private app built from a known post-target-contract commit, not an arbitrary installed app with the same version number. The collection setup supplies `~/.local/share/minga/rejection-sessions/build.json`, which records that actual build's command, immutable source commit, app path, and payload hash. The collector verifies the payload at both boundaries. A payload hash alone does not establish source provenance; review the build receipt before accepting sessions.

Quit any existing Minga instance normally before collection. The collector refuses to begin or finish while Minga is running; it never terminates an app. Confirm that `:log_level_editor` permits warnings (`:debug`, `:info`, or `:warning`), and keep that setting throughout the session. The level is an operator declaration, not a runtime measurement.

```bash
/usr/bin/python3 scripts/collect_rejection_sessions.py begin \
  --build "$HOME/.local/share/minga/rejection-sessions/build.json" \
  --kind real --warning-level warning \
  --note "Normal work on the application project" .
```

Run the printed `Run:` command. It uses the private app's standard bundled launcher, with only diagnostic output redirection added. The collector does not launch, reopen, wait for, or replace native instances. If the singleton window is restored closed, click that app's Dock icon. Use it for normal work, quit normally, then run the printed `Finish:` command.

Finish asks you to confirm the prescribed launch, one uninterrupted session without replacement or restart, normal work for real captures, clean quit, and uninterrupted warning capture. Answer no if any condition is uncertain. If you cancel before launching, finish and answer no to release the bracket while retaining an unknown count. A canonical log can have only one unfinished bracket, even when collection roots differ. Python 3.9 or later is required; the example uses the system Python tested on macOS.

These are **operator-bracketed, log-verified real-session candidates**, not independently observed native lifetimes. The timestamps are collection boundaries. Neither the human work, native instance continuity, native exit, nor warning configuration can be proved by these logs alone. The operator's exact-launch and no-restart confirmation is part of the evidence.

Each capture directory retains `session.json`, `debug.log`, `canonical.log`, `native-output.log`, `launcher-output.log`, and `report.json`, plus its generated launch scripts and launcher status. Final byte counts and SHA-256 hashes detect later evidence loss or modification. Session directories are private, but their contents can include file paths and other sensitive editor messages. Review before sharing.

```bash
/usr/bin/python3 scripts/collect_rejection_sessions.py report
```

The report lists candidates, not an automatic decision to close the investigation. Review their work notes, build provenance, and declarations. Captures with `--kind smoke` never count as real sessions. Missing or changed logs, failed debug writers, restarts, unconfirmed boundaries, registry gaps, changed canonical-log boundaries, and missing or ambiguous rejection matches produce an unknown count, not zero. An attested clean quit may end with the registry's exact terminal `:shutdown` marker; a mid-session shutdown or recovery remains a gap. Unattributed canonical rejections also make the count unknown, so avoid running rejection-producing tests during collection.

Copied captures are not additional sessions; the cohort count deduplicates validated debug-log hashes.

The default canonical path is the native app's `~/.local/share/minga/minga.log`. Launch Services does not inherit a shell-only `XDG_DATA_HOME`; use `--canonical` only when the native app is explicitly configured to write elsewhere.

Ten accepted real sessions satisfy the frequency sample, including complete sessions with zero rejections. They do not replace the recovery-cost measurement, preview inventory, or written protocol decision required by #3513.

## Commit Messages

```
type(scope): short description
```

**Types:** `feat`, `fix`, `refactor`, `test`, `docs`, `chore` **Scopes:** `buffer`, `port`, `editor`, `mode`, `keymap`, `zig`, `cli`

Examples:
- `feat(buffer): implement gap buffer with cursor movement`
- `fix(editor): reparse highlights on normal-mode operators`
- `test(buffer): add property-based tests for insert/delete`

## Updating Documentation

When you finish a feature or change the architecture, update:
- **`docs/ARCHITECTURE.md`**: if you add process types, opcodes, or change supervision
