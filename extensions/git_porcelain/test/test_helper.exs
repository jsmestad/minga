ExUnit.start(max_cases: 1)

defmodule MingaGitPorcelain.TestClipboard do
  @behaviour Minga.Clipboard.Behaviour

  @impl true
  def read, do: nil

  @impl true
  def write(_text), do: :ok
end

Application.put_env(:minga, :clipboard_module, MingaGitPorcelain.TestClipboard)
Application.put_env(:minga, :load_file_tree_extension, false)
Application.put_env(:minga, :load_git_porcelain_extension, true)
Application.put_env(:minga, :git_module, Minga.Git.Stub)

parent_test_support = Path.expand("../../../test/support", __DIR__)

Code.require_file(Path.join(parent_test_support, "git_stub.ex"))
Minga.Git.Stub.ensure_table()
Code.require_file(Path.join(parent_test_support, "headless_port.ex"))
Code.require_file(Path.join(parent_test_support, "render_pipeline_test_helpers.ex"))
Code.require_file(Path.join(parent_test_support, "editor_case.ex"))
