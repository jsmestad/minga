ExUnit.start(capture_log: true)

# Disable clipboard sync during tests to avoid race conditions from
# parallel tests sharing the system clipboard. Tests that specifically
# test clipboard behavior set clipboard: :unnamedplus in their setup.
Minga.Config.Options.set(:clipboard, :none)
