# Autoresearch: Fix Flaky Tests

## Goal
Eliminate timing-dependent test patterns (Process.sleep, :timer.sleep, polling loops) across the Elixir test suite. Each iteration fixes one test file by replacing sleep/poll patterns with proper OTP synchronization.

## Metric
`flaky_patterns` — count of finite Process.sleep/:timer.sleep calls in test files (lower is better). Measured by `autoresearch.bench.sh`.

## Rules
1. **No "wait longer" fixes** — don't increase sleep durations
2. **No `async: false` changes** — don't serialize tests to hide races
3. **True fixes only** — use `:sys.get_state` barriers, `Process.monitor`, `assert_receive`, event subscriptions, or GenServer call synchronization
4. **One file per iteration** — fix one test file, verify it passes 5x, measure
5. **Exclude legitimate uses** — `spawn(fn -> Process.sleep(:infinity) end)` (dummy processes) and timeout-testing code are not flaky patterns
6. **Consult test-advisor** when you can't find a way to eliminate the dependency on globals or time, or when you believe a test isn't valuable to keep

## Priority (from CI failure frequency)
1. `chaos/editor_fuzzer_test.exs` — 8 CI failures (HeadlessPort.collect_frame timeout)
2. `buffer/decorations_benchmark_test.exs` — 4 CI failures (tree height assertion)
3. `tool/manager_test.exs` — 6x `:timer.sleep(200)` (async task completion)
4. `editor/warnings_buffer_test.exs` — 3x `Process.sleep(300)` (async cast barrier)
5. `parser/multi_buffer_test.exs` — 2x `Process.sleep(50)` (parser readiness)
6. `parser/incremental_test.exs` — 2x `Process.sleep(50/20)` (parser readiness)
7. `editor/file_tree_integration_test.exs` — `Process.sleep(50)` + polling
8. `git/tracker_test.exs` — polling with `Process.sleep(interval)`
9. `command_output_test.exs` — polling with `Process.sleep(5)`
10. `project_test.exs` — `Process.sleep(10)` + polling rebuild
11. `agent/providers/native_test.exs` — 6x `Process.sleep(50-100)` (streaming timing)

## Synchronization patterns to use
- `:sys.get_state(pid)` — flushes GenServer mailbox, ensures prior casts processed
- `Process.monitor(pid)` + `assert_receive {:DOWN, ...}` — wait for process exit
- `assert_receive {:event, ...}` — wait for specific messages
- GenServer.call as barrier — any sync call blocks until mailbox drained
- `receive ... after timeout -> flunk()` — wait for specific messages with deadline
