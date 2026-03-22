# Autoresearch: Convert async: false tests to async: true

## Goal
Reduce the number of `async: false` test files by making global singletons injectable (pass name/table reference instead of hardcoding). Each conversion moves tests from the sync queue to the async queue, speeding up CI.

## Metric
`async_false_count` — number of test files containing `async: false` (lower is better). Measured by `autoresearch.bench.sh`.

## Rules
1. **Make singletons injectable** — add a `name:` option to GenServers/ETS modules so tests can start private instances
2. **No behavior changes** — production code should work identically; the default name stays the same
3. **One module per iteration** — refactor one production module, convert its test(s) to async: true, verify 3x
4. **Don't convert tests with legitimate reasons** — OS Port spawning (erl_child_setup EPIPE), capture_io(:stderr), System env mutation
5. **Consult test-advisor** when unsure if a test is safe to convert

## Priority (by test count, highest impact first)

### Convertible with production refactoring
| Tests | File | Blocker | Fix |
|-------|------|---------|-----|
| 42 | popup/{lifecycle,registry}_test.exs | Popup.Registry global ETS | Add name: param to Registry |
| 77 | config_test + config/loader_test + formatter_test + log_routing | Options/Hooks/Keymap globals | Add name: to Options |
| 85 | mode/{visual,insert}_test + keymap/scope + minga_org_test | KeymapActive global | Add name: to KeymapActive |
| 16 | events_test.exs | Shared EventBus | May already be safe (subscribe is idempotent) |

### Likely safe without production changes (investigate)
| Tests | File | Why async:false | Investigation |
|-------|------|-----------------|---------------|
| 39 | filetype_test.exs | "shared Agent state" | Check if Agent is test-local |
| 16 | git/repo_test.exs | No stated reason | Check for globals |
| 12 | tool/manager_test.exs | Global ETS | Already uses Events; might work |
| 11 | perf/document_perf_test.exs | No stated reason | Likely perf isolation |
| 8 | config/hooks_test.exs | No stated reason | Check for globals |

### Cannot convert (legitimate reasons)
- OS Port: gui_protocol_test, lsp/*, parser/*, command_output_test, tree_sitter_test, git/backend_operations, clipboard/system_test, extension/git_test
- capture_io: eval_test
- Env mutation: credentials_test, startup_test
- Global handlers: telemetry/*
