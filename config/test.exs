import Config

# Only show warnings and errors during test runs. Info-level messages
# from app startup (extension loading, grammar registration) would
# otherwise pollute test output before ExUnit's capture_log kicks in.
config :logger, level: :warning
