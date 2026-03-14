import Config

# Only show warnings and errors during test runs. Info-level messages
# from app startup (extension loading, grammar registration) would
# otherwise pollute test output before ExUnit's capture_log kicks in.
config :logger, level: :warning

# Speed up CLI tests: the editor isn't running in test, so
# wait_for_editor always times out. Use fast poll params (5ms × 4 = 20ms)
# instead of the production default (50ms × 20 = 1s).
config :minga, editor_wait_params: {5, 4}
