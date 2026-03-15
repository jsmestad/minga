Hammox.defmock(Minga.Clipboard.Mock, for: Minga.Clipboard.Behaviour)
Application.put_env(:minga, :clipboard_module, Minga.Clipboard.Mock)

# Initialize the Git.Stub ETS table for in-memory git responses.
Minga.Git.Stub.ensure_table()

# Suppress "warning: templates not found in ~/.git_template" noise from
# git init calls in tests. An empty string tells git to skip templates.
System.put_env("GIT_TEMPLATE_DIR", "")

ExUnit.start(capture_log: true, exclude: [:pi])

# Disable clipboard sync during tests to avoid race conditions from
# parallel tests sharing the system clipboard. Tests that specifically
# test clipboard behavior set clipboard: :unnamedplus in their setup.
Minga.Config.Options.set(:clipboard, :none)
