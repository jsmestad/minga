defmodule MingaAgent.Tools.ProjectViewProcessRoutingTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.Test.RecordingProcessBackend
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    working_dir = Path.join(dir, "view")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(working_dir, "lib"))

    {:ok, view} =
      RecordingBackend.create(root,
        parent: self(),
        working_dir: working_dir,
        workspace_id: 42,
        env: [{"PROJECT_VIEW_SENTINEL", "present"}]
      )

    tools =
      Tools.all(
        project_root: root,
        project_view: view,
        process_backend: RecordingProcessBackend
      )

    %{root: root, tools: tools, working_dir: working_dir}
  end

  test "find, grep, and shell receive ProjectView execution context", %{
    root: root,
    tools: tools,
    working_dir: working_dir
  } do
    assert {:ok, find_result} = call_tool(tools, "find", %{"pattern" => "*.txt", "path" => "lib"})
    assert find_result =~ "path=#{Path.join(working_dir, "lib")}"
    assert find_result =~ "filter_root: #{inspect(Path.join(root, "lib"))}"
    assert find_result =~ "ProjectView workspace 42"

    assert {:ok, grep_result} =
             call_tool(tools, "grep", %{
               "pattern" => "needle",
               "path" => "lib",
               "case_sensitive" => false
             })

    assert grep_result =~ "path=#{Path.join(working_dir, "lib")}"
    assert grep_result =~ "case_sensitive"
    assert grep_result =~ "ProjectView workspace 42"

    assert {:ok, shell_result} = call_tool(tools, "shell", %{"command" => "echo hello"})
    assert shell_result =~ "cwd=#{working_dir}"
    assert shell_result =~ "PROJECT_VIEW_SENTINEL"
    assert shell_result =~ "ProjectView workspace 42"
  end

  @spec call_tool([ReqLLM.Tool.t()], String.t(), map()) ::
          MingaAgent.Tools.ProcessBackend.result()
  defp call_tool(tools, name, args) do
    tools
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:callback)
    |> then(& &1.(args))
  end
end
