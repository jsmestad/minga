ExUnit.start(max_cases: 1)

defmodule MingaGitPorcelain.TestClipboard do
  @behaviour Minga.Clipboard.Behaviour

  @impl true
  def read, do: nil

  @impl true
  def write(_text), do: :ok
end

Application.put_env(:minga, :clipboard_module, MingaGitPorcelain.TestClipboard)
Application.put_env(:minga, :load_extensions, true)
Application.put_env(:minga, :git_module, Minga.Git.Stub)

{:ok, standalone_root} = Minga.Project.Root.directory(File.cwd!())
{:ok, _snapshot} = Minga.Project.activate(standalone_root)

parent_test_support = Path.expand("../../../test/support", __DIR__)

unless Code.ensure_loaded?(Minga.Git.Stub),
  do: Code.require_file(Path.join(parent_test_support, "git_stub.ex"))

Minga.Git.Stub.ensure_table()

unless Code.ensure_loaded?(Minga.Test.HeadlessPort),
  do: Code.require_file(Path.join(parent_test_support, "headless_port.ex"))

unless Code.ensure_loaded?(MingaEditor.RenderPipeline.TestHelpers),
  do: Code.require_file(Path.join(parent_test_support, "render_pipeline_test_helpers.ex"))

unless Code.ensure_loaded?(Minga.Test.EditorCase),
  do: Code.require_file(Path.join(parent_test_support, "editor_case.ex"))
