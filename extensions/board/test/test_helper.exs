ExUnit.start()

Hammox.defmock(Minga.Clipboard.Mock, for: Minga.Clipboard.Behaviour)
Application.put_env(:minga, :clipboard_module, Minga.Clipboard.Mock)
Application.put_env(:minga, :load_extensions, false)
Application.put_env(:minga, :load_file_tree_extension, false)
Application.put_env(:minga, :load_git_porcelain_extension, false)
Application.put_env(:minga, :load_board_extension, false)

parent_test_support = Path.expand("../../../test/support", __DIR__)

Code.require_file(Path.join(parent_test_support, "headless_port.ex"))
Code.require_file(Path.join(parent_test_support, "snapshot.ex"))
Code.require_file(Path.join(parent_test_support, "stub_server.ex"))
Code.require_file(Path.join(parent_test_support, "editor_case.ex"))
Code.require_file(Path.join(parent_test_support, "render_pipeline_test_helpers.ex"))

MingaEditor.Shell.Registry.reset_for_test()
MingaEditor.Shell.Registry.seed_builtin()
MingaBoard.Feature.register_contributions()
