defmodule MingaAgent.Tools.ProjectViewProcessRoutingTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.ProjectView.UnavailableBackend
  alias MingaAgent.Test.RecordingProcessBackend
  alias MingaAgent.Tool.Context
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

    context =
      MingaAgent.Tool.Context.new(
        project_root: root,
        project_view: view,
        metadata: %{process_backend: RecordingProcessBackend}
      )

    %{root: root, context: context, working_dir: working_dir}
  end

  test "find, grep, and shell receive ProjectView execution context", %{
    root: root,
    context: context,
    working_dir: working_dir
  } do
    assert {:ok, find_result} =
             call_tool(context, "find", %{"pattern" => "*.txt", "path" => "lib"})

    assert find_result =~ "path=#{Path.join(working_dir, "lib")}"
    assert find_result =~ "filter_root: #{inspect(Path.join(root, "lib"))}"
    assert find_result =~ "ProjectView workspace 42"

    assert {:ok, grep_result} =
             call_tool(context, "grep", %{
               "pattern" => "needle",
               "path" => "lib",
               "case_sensitive" => false
             })

    assert grep_result =~ "path=#{Path.join(working_dir, "lib")}"
    assert grep_result =~ "case_sensitive"
    assert grep_result =~ "ProjectView workspace 42"

    assert {:ok, shell_result} = call_tool(context, "shell", %{"command" => "echo hello"})
    assert shell_result =~ "cwd=#{working_dir}"
    assert shell_result =~ "PROJECT_VIEW_SENTINEL"
    assert shell_result =~ "ProjectView workspace 42"
  end

  test "routing failures prevent find, grep, and shell process execution", %{root: root} do
    {:ok, view} = UnavailableBackend.create(root, workspace_id: 99)

    context =
      Context.new(
        project_root: root,
        project_view: view,
        metadata: %{process_backend: RecordingProcessBackend}
      )

    for {name, args} <- [
          {"find", %{"pattern" => "*.txt", "path" => "lib"}},
          {"grep", %{"pattern" => "needle", "path" => "lib"}},
          {"shell", %{"command" => "echo must-not-run"}}
        ] do
      assert {:error, message} = call_tool(context, name, args)
      assert message =~ "project_view_unavailable"
    end
  end

  test "a terminated changeset prevents find, grep, and shell process execution", %{root: root} do
    {:ok, changeset} =
      start_supervised({MingaAgent.Changeset.Server, project_root: root})

    context =
      Context.new(
        project_root: root,
        changeset: changeset,
        metadata: %{process_backend: RecordingProcessBackend}
      )

    ref = Process.monitor(changeset)
    Process.exit(changeset, :kill)
    assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

    for {name, args} <- [
          {"find", %{"pattern" => "*.txt", "path" => "lib"}},
          {"grep", %{"pattern" => "needle", "path" => "lib"}},
          {"shell", %{"command" => "echo must-not-run"}}
        ] do
      assert {:error, message} = call_tool(context, name, args)
      assert message =~ "noproc"
    end
  end

  @spec call_tool(MingaAgent.Tool.Context.t(), String.t(), map()) ::
          MingaAgent.Tools.ProcessBackend.result()
  defp call_tool(context, name, args) do
    spec = Enum.find(Tools.all(), &(&1.name == name))
    callback = MingaAgent.Tool.Spec.build_callback(spec, context)
    callback.(args)
  end
end
