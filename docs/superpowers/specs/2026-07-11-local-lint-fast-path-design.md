# Local lint fast path

## Decision

Make `make lint` the frequent local gate: formatting, changed-file Credo, warnings-as-errors compilation, and native OTP incremental Dialyzer. Add `make lint.full` for the existing full Credo and classic Dialyxir checks. CI remains unchanged and continues to run full Credo and classic Dialyxir before merge.

## Why this change

The current local lint command runs 129 Credo checks across 1,923 files and sends all 1,138 compiled Minga BEAMs to classic Dialyzer on every invocation. Measured local runs took 24 to 80 seconds for Credo and 2 minutes 19 seconds to 5 minutes 48 seconds for Dialyzer. Credo already uses all available schedulers, Minga's custom checks account for about two seconds, and the existing Dialyxir PLT already limits dependencies to direct runtime applications. The expensive work is the full-project scope.

Credo can check explicitly named source files in about 2.5 seconds for one file. OTP 29 includes native incremental Dialyzer analysis, which persists an incompatible incremental PLT and reanalyzes only modules affected by a change. Minga can use that engine directly without adding an immature third-party dependency.

## Commands

`make lint` runs the fast local gate. It checks all formatting, runs Credo against changed Elixir sources, compiles with warnings treated as errors, and runs the native incremental type check.

`make lint.full` runs the full gate. It checks all formatting, runs full Credo, compiles, and runs the existing `mix dialyzer` command. Credo runs alongside the compile and Dialyzer sequence so it does not add to the full command's wall time on machines with enough memory. The command still reports failures from every check.

`make lint.credo` remains the explicit full Credo command. `make lint.dialyzer` remains the explicit classic Dialyxir command. `make lint.dialyzer.incremental` runs the native incremental task directly for diagnosis and cache warm-up.

## Changed-file Credo

A small script invoked by `make lint` collects changed Elixir files from the branch diff, staged and unstaged changes, and untracked files. It passes those paths positionally to Credo, which is the only Credo interface that narrows the source set. A run with no relevant files succeeds without invoking Credo.

The script falls back to full Credo when `.credo.exs`, `mix.exs`, or a file under `credo/checks/` changes because those changes alter the checks or their configuration for every source file.

`Minga.Credo.CommandRegistrationCheck` reads command sources from disk but only runs when Credo visits `lib/minga/command/parser.ex`. When a changed path can affect that check, including the command parser, command dispatch files, command registry, or provider modules, the script also includes the parser source in the Credo invocation. This preserves the cross-file command-registration guarantee while keeping ordinary edits narrow.

## Incremental Dialyzer

Add `Mix.Tasks.Dialyzer.Incremental` under `mix/tasks/` and load it from `mix.exs`. The task owns only incremental lifecycle behavior. It reuses Dialyxir's existing project application scope, project BEAM discovery, warning configuration, and ignore-file filtering so classic and incremental checks have the same inputs and filtered diagnostics.

The task runs OTP's `:dialyzer` with incremental analysis enabled. It supplies application BEAM directories as analysis inputs and the Minga application directory as the warning scope. It writes an incremental PLT under `_build/<env>/dialyzer_incremental/`, separated from Dialyxir's classic PLT and keyed by the active OTP and Elixir versions plus a fingerprint of `mix.lock` and the Dialyzer configuration.

Each run creates an exclusive cache lock. A concurrent invocation fails with a clear message instead of corrupting the PLT. The task writes to a unique temporary PLT and atomically replaces the completed cache only after Dialyzer succeeds. It removes its own temporary output in an `after` block. A targeted cleanup command removes the incremental cache when manual recovery is needed.

The task passes a metrics path to native Dialyzer and prints the changed and reanalyzed module counts after a successful run. This makes the cache behavior observable instead of assuming it is incremental.

## Dependency scope

Change `StreamData` to `only: :test`. It has no production source references and its application has no runtime processes, but its current `:dev` inclusion adds it to Minga's dev application dependency graph and therefore to the Dialyxir PLT. Burrito remains a runtime dependency because Minga's CLI, application startup, and safe-mode code call `Burrito.Util`.

No other PLT application is removed in this change. The remaining applications are direct runtime support or explicit type context for modules Minga calls. Removing them would reduce type facts rather than remove unused work.

## Validation

The implementation must prove the fast path is correct before delivery:

1. Run full Credo and classic Dialyxir before and after the change with no new filtered warnings.
2. Exercise changed-file Credo with a normal source edit, an untracked source file, no relevant changes, a Credo configuration change, and a command-registration input change.
3. Run incremental Dialyzer cold, unchanged, after a source edit, after a renamed or deleted source, and after a lockfile or Dialyzer configuration change. Compare its filtered warnings to classic Dialyxir for each applicable state.
4. Verify a concurrent incremental invocation fails without replacing the current cache, and an interrupted temporary output does not become the cache.
5. Run `make lint`, `make lint.full`, `mix test.llm`, `make lint`, and the final project checks required for touched Elixir and documentation files.

## Documentation updates

Update `Makefile` help text, `CONTRIBUTING.md`, and `AGENTS.md` so contributors know that `make lint` is the fast local gate, `make lint.full` is the complete local gate, and CI remains the classic Dialyxir authority.
