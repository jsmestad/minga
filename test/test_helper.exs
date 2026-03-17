Hammox.defmock(Minga.Clipboard.Mock, for: Minga.Clipboard.Behaviour)
Application.put_env(:minga, :clipboard_module, Minga.Clipboard.Mock)

# Initialize the Git.Stub ETS table for in-memory git responses.
Minga.Git.Stub.ensure_table()

# Suppress "warning: templates not found in ~/.git_template" noise from
# git init calls in tests. An empty string tells git to skip templates.
System.put_env("GIT_TEMPLATE_DIR", "")

# Exclude Swift harness tests when the binary isn't built (CI Linux, or dev without `mix swift.harness`).
harness_path = Path.join(:code.priv_dir(:minga), "minga-test-harness")
swift_exclude = if File.exists?(harness_path), do: [], else: [:swift_harness]

ExUnit.start(capture_log: true, exclude: [:pi | swift_exclude])

# Disable clipboard sync during tests to avoid race conditions from
# parallel tests sharing the system clipboard. Tests that specifically
# test clipboard behavior set clipboard: :unnamedplus in their setup.
Minga.Config.Options.set(:clipboard, :none)
