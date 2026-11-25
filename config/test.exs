import Config

# Keep Minga state private without changing HOME, which Mix and tools such as asdf need.
# Allocate a fresh root rather than adopting an older test namespace or inherited XDG state.
test_profile =
  Path.join(
    System.tmp_dir!(),
    "minga-test-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  )

File.mkdir!(test_profile)

for {env, subdir} <- [
      {"XDG_CONFIG_HOME", "config"},
      {"XDG_DATA_HOME", "data"},
      {"XDG_CACHE_HOME", "cache"},
      {"XDG_STATE_HOME", "state"}
    ] do
  path = Path.join(test_profile, subdir)
  File.mkdir!(path)
  System.put_env(env, path)
end

File.mkdir!(Path.join([test_profile, "config", "minga"]))

# Only show warnings and errors during test runs. Info-level messages
# from app startup (extension loading, grammar registration) would
# otherwise pollute test output before ExUnit's capture_log kicks in.
config :logger, level: :warning

# Use the inert git stub so tests don't spawn git subprocesses. This
# prevents erl_child_setup EPIPE errors from concurrent async tests.
# Tests that need real git (git integration tests) override this in setup.
config :minga, git_module: Minga.Git.Stub

# Agent overlays link installed JavaScript packages instead of cloning them
# with the minga-clone-tree helper, so async tests never spawn it. Clone tests
# pick a cloner explicitly.
config :minga, overlay_cloner: MingaAgent.Test.Overlay.UnsupportedCloner

# Use the platform stub so tests don't shell out to osascript/gio for
# trash operations. Tests that need real trash behavior override this in setup.
config :minga, platform_module: Minga.Platform.Stub

# Keep generic editor startup tests hermetic. Tests that verify startup root
# inference opt in with `infer_project_root: true`.
config :minga, infer_startup_project_root: false

# Use a lightweight stub provider for agent sessions in tests.
# The real native provider takes ~700ms to start because it loads tools
# and resolves API keys. The stub starts instantly and satisfies the
# Session GenServer lifecycle.
config :minga, test_provider_module: Minga.Test.StubProvider

# Do not load the model catalog in the background for every test Editor. Tests
# that cover the preload call it directly.
config :minga, agent_catalog_preload: false

# Test VMs load modules on demand; do not load the whole app per test Editor.
config :minga, launch_code_warmup: false

# Disable user extension loading so tests are deterministic regardless
# of which extensions the developer has installed locally.
config :minga, load_extensions: false
# Unit suites start path extensions against private admission authorities after
# application boot; production seals the default authority after initial load.
config :minga, seal_extension_artifact_generation: false
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

# Disable the which-key popup timer in tests. The timer fires after 300ms
# and triggers an extra render, which can steal frame waiters from the
# headless test harness. Setting :infinity prevents the timer from firing
# while still allowing the which-key popup to render via explicit tests.
config :minga, whichkey_timeout_ms: :infinity

# Disable OS-level agent notifications (osascript) in tests to prevent
# real macOS notifications from firing during the test suite.
config :minga, os_notify_adapter: MingaAgent.Notifier.OSAdapter.Noop
