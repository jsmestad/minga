import Config

# Only show warnings and errors during test runs. Info-level messages
# from app startup (extension loading, grammar registration) would
# otherwise pollute test output before ExUnit's capture_log kicks in.
config :logger, level: :warning

# Use the inert git stub so tests don't spawn git subprocesses. This
# prevents erl_child_setup EPIPE errors from concurrent async tests.
# Tests that need real git (git integration tests) override this in setup.
config :minga, git_module: Minga.Git.Stub

# Speed up CLI tests: the editor isn't running in test, so
# wait_for_editor always times out. Use fast poll params (5ms × 4 = 20ms)
# instead of the production default (50ms × 20 = 1s).
config :minga, editor_wait_params: {5, 4}

# Use a lightweight stub provider for agent sessions in tests.
# The real providers (Native, PiRpc) take ~700ms to start because they
# load tools, resolve API keys, or spawn OS processes. The stub starts
# instantly and satisfies the Session GenServer lifecycle.
config :minga, test_provider_module: Minga.Test.StubProvider

# Use stub installers in tests to avoid spawning npm/pip/cargo/go/curl
# subprocesses during concurrent test runs (same EPIPE concern as git).
config :minga,
  tool_installers: %{
    npm: Minga.Tool.Installer.Stub,
    pip: Minga.Tool.Installer.Stub,
    cargo: Minga.Tool.Installer.Stub,
    go_install: Minga.Tool.Installer.Stub,
    github_release: Minga.Tool.Installer.Stub
  }
