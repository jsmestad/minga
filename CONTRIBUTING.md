# Contributing to Minga

Thanks for your interest! Minga is in early development and contributions are welcome, whether that's bug reports, feature ideas, or code.

## Build from source

Minga is two programs: an Elixir app (editor logic) and a Zig binary (terminal rendering). You need both toolchains plus Erlang. A version manager makes this painless.

### Install the toolchain

Using [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/):

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf plugin add zig
```

### Clone and build

```bash
git clone https://github.com/jsmestad/minga.git
cd minga
asdf install          # Installs pinned Erlang, Elixir, Zig from .tool-versions
mix deps.get
mix compile           # Builds both Elixir and Zig
```

The first build takes a few minutes (Zig compiles tree-sitter grammars for 24 languages). After that, rebuilds are incremental and fast.

### Run it

```bash
bin/minga              # Empty buffer
bin/minga path/to/file # Open a file
```

## Running Tests

```bash
mix test                       # Elixir tests
cd zig && zig build test       # Zig renderer tests
```

## Before Committing

Run the fast local gate once before requesting review. CI owns the full gate; `make lint.full` exists for reproducing a CI failure locally.

```bash
make lint                         # Formatting + changed Credo + ExDNA, in parallel with compile -> incremental Dialyzer + Reach arch policy (~25s warm)
make lint.full                    # Same plus full Credo, Reach smells, and classic Dialyzer (minutes)
mix test.llm                      # Non-heavy test suite with an LLM-friendly summary
```

Both gates run every independent check even when one fails (Dialyzer and Reach are skipped only when compile fails) and print one status line per check followed by the logs of the failed ones. The fast gate skips compile, Dialyzer, Reach, and ExDNA on branches with no Elixir-relevant change. CI also runs full Credo, ExDNA, Reach, and classic Dialyzer before merge.

## Project Layout

See `AGENTS.md` (in the repo root) for the full project structure, coding standards, and conventions. The highlights:

- **`@spec` on every public function**: Elixir 1.19's type system is strict
- **Pattern matching over `if`/`cond`**: multi-clause functions preferred
- **Test files mirror `lib/`**: `lib/minga/buffer/document.ex` → `test/minga/buffer/document_test.exs`
- **Property-based tests** with StreamData for data structures

## Key Documentation

| Doc | What it covers |
|-----|---------------|
| [README.md](README.md) | Project overview and quick start |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Two-process design, supervision, port protocol |
| [docs/MACOS_ACCESSIBILITY_TESTING.md](docs/MACOS_ACCESSIBILITY_TESTING.md) | Real launched-app macOS accessibility validation |
| `AGENTS.md` | Coding standards, project structure, how to add features |

## How to Add Things

### A new command
1. Define in `Minga.Command.Registry` with name + description
2. Add keybinding in `Minga.Keymap.Defaults`
3. Implement in the appropriate `lib/minga/editor/commands/*.ex` module
4. Test the command and the keybinding lookup

### A new motion
1. Add function to the appropriate `lib/minga/motion/*.ex` module with `@spec`
2. Wire into `Minga.Mode.Normal` and `Minga.Mode.OperatorPending`
3. Test against known buffer content, including Unicode edge cases

### A new text object
1. Add function to `Minga.TextObject` with `@spec`
2. Register in `Minga.Mode.OperatorPending`
3. Test: cursor inside, cursor outside, nested, empty content

### A new render command (both sides)
1. Add opcode + encoder in `Minga.Port.Protocol`
2. Add decoder + handler in `zig/src/protocol.zig` and `zig/src/renderer.zig`
3. Test encode/decode round-trip on both sides

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
