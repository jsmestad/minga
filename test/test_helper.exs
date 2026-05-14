Hammox.defmock(Minga.Clipboard.Mock, for: Minga.Clipboard.Behaviour)
Application.put_env(:minga, :clipboard_module, Minga.Clipboard.Mock)

# Initialize the Git.Stub ETS table for in-memory git responses.
Minga.Git.Stub.ensure_table()

# Initialize the Tool.Installer.Stub ETS table so Tool.Manager doesn't
# crash if it spawns an install task before any test calls Stub.reset().
Minga.Tool.Installer.Stub.ensure_table()

# Suppress "warning: templates not found in ~/.git_template" noise from
# git init calls in tests. An empty string tells git to skip templates.
System.put_env("GIT_TEMPLATE_DIR", "")

# Suppress "hint: Using 'master' as the name for the initial branch" noise
# from git init calls. Uses the same env-var mechanism as GIT_TEMPLATE_DIR
# so all tests that call `git init` inherit the setting automatically.
System.put_env("GIT_CONFIG_COUNT", "1")
System.put_env("GIT_CONFIG_KEY_0", "init.defaultBranch")
System.put_env("GIT_CONFIG_VALUE_0", "main")

# Auto-build the Swift test harness on macOS if swiftc is available.
# On Linux (CI), the harness tests are excluded automatically.
harness_path = Path.join(:code.priv_dir(:minga), "minga-test-harness")

case System.find_executable("swiftc") do
  nil -> :noop
  _swiftc -> Mix.Task.run("swift.harness")
end

swift_exclude = if File.exists?(harness_path), do: [], else: [:swift_harness]

ExUnit.start(capture_log: true, exclude: [:pi | swift_exclude])

# Disable clipboard sync during tests to avoid race conditions from
# parallel tests sharing the system clipboard. Tests that specifically
# test clipboard behavior set clipboard: :unnamedplus in their setup.
Minga.Config.Options.set(:clipboard, :none)

# Disable auto-save globally in tests to avoid background disk writes from
# unrelated file-buffer tests. Auto-save tests opt in per buffer.
Minga.Config.Options.set(:auto_save_delay_ms, 0)

# Disable LSP auto-start globally in tests so unrelated buffer-open events do
# not leak real language-server clients into tests that assert no LSP is active.
Minga.Config.Options.set(:lsp_auto_start, false)

# Disable persisting known projects and recent files during tests to avoid
# polluting ~/.config/minga/known-projects with test fixture directories.
Minga.Config.Options.set(:persist_known_projects, false)
Minga.Config.Options.set(:persist_recent_files, false)

# Tests that create editors directly should pass `editing_model:` to
# `MingaEditor.start_link/1` instead of mutating global config.
