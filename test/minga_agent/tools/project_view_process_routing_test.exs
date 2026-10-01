defmodule MingaAgent.Tools.ProjectViewProcessRoutingTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView.UnavailableBackend
  alias MingaAgent.Test.RecordingProcessBackend
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    File.mkdir_p!(Path.join(root, "lib"))

    %{root: root}
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
