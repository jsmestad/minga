# Test Suite Optimization Ideas

## Done
- ~~CLI test polling~~ (fixed: configurable via app env)
- ~~MingaOrg clone per test~~ (fixed: setup_all)

## Remaining (~5s of irreducible test time)
- **Retry.ex data clump**: `attempt_num`, `max_retries`, `on_retry`, `base_delay` are passed as separate arguments through 5+ private functions. Extract a `%RetryConfig{}` struct to reduce parameter explosion. Pre-existing issue made slightly worse by adding `base_delay_ms`.
- ~~**Agent session nil-path tests**~~ (fixed: StubProvider in test config)
- **Shell real-timeout tests** (~2s, 2 tests): `sleep 1` for running indicator and `sleep 60` with 1s timeout. Irreducible unless the indicator threshold is further lowered in tests.
- **Zig grammar compilation** (~1s, 3 tests): Real compiler invocation. Could cache compiled .so across test runs via a persistent temp dir.
- **LSP mock server startup** (~1.5s across ~6 tests): Real Port-based Elixir process with JSON-RPC handshake. Inherent to testing real LSP communication.
- **Git tool tests** (~0.5s): Real git commands in temp repos. Irreducible.
