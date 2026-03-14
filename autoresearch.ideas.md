# Test Suite Optimization Ideas

- **Retry.ex data clump**: `attempt_num`, `max_retries`, `on_retry`, `base_delay` are passed as separate arguments through 5+ private functions. Extract a `%RetryConfig{}` struct to reduce parameter explosion. Pre-existing issue made slightly worse by adding `base_delay_ms`.
- **CLI test polling**: `wait_for_editor(50, 20)` polls for 1s when editor isn't running. Could make interval/retries configurable to save ~2s across 2 tests.
- **MingaOrg tests**: Real git clone + Zig compilation (~6s). Could cache the clone across test runs or move to a separate `@tag :slow` suite.
