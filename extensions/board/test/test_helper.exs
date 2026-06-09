ExUnit.start()

unless Code.ensure_loaded?(Minga.Clipboard.Mock) do
  Hammox.defmock(Minga.Clipboard.Mock, for: Minga.Clipboard.Behaviour)
end

Application.put_env(:minga, :clipboard_module, Minga.Clipboard.Mock)
Application.put_env(:minga, :load_extensions, false)
Application.put_env(:minga, :load_file_tree_extension, false)
Application.put_env(:minga, :load_git_porcelain_extension, false)
Application.put_env(:minga, :load_board_extension, false)

parent_test_support = Path.expand("../../../test/support", __DIR__)

unless Code.ensure_loaded?(Minga.Test.HeadlessPort) do
  Code.require_file(Path.join(parent_test_support, "headless_port.ex"))
end

unless Code.ensure_loaded?(Minga.Test.Snapshot) do
  Code.require_file(Path.join(parent_test_support, "snapshot.ex"))
end

unless Code.ensure_loaded?(Minga.Test.StubServer) do
  Code.require_file(Path.join(parent_test_support, "stub_server.ex"))
end

unless Code.ensure_loaded?(Minga.Test.EditorCase) do
  Code.require_file(Path.join(parent_test_support, "editor_case.ex"))
end

unless Code.ensure_loaded?(MingaEditor.RenderPipeline.TestHelpers) do
  Code.require_file(Path.join(parent_test_support, "render_pipeline_test_helpers.ex"))
end

MingaEditor.Shell.Registry.reset_for_test()
MingaEditor.Shell.Registry.seed_builtin()
MingaBoard.Feature.register_contributions()
