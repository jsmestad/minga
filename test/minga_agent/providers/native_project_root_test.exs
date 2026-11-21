defmodule MingaAgent.Providers.NativeProjectRootTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView
  alias MingaAgent.Providers.Native
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.Test.RetainedContextFixture
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Spec
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  test "a session started with the editor's project view roots its tools at that project, not the launch directory",
       %{tmp_dir: dir} do
    dir = Path.expand(dir)
    project = Path.join(dir, "project")
    launch_dir = Path.join(dir, "launch")
    File.mkdir_p!(project)
    File.mkdir_p!(launch_dir)
    File.write!(Path.join(project, "notes.md"), "project notes\n")
    File.write!(Path.join(launch_dir, "notes.md"), "launch notes\n")

    {:ok, view} = ProjectView.overlay(project)
    on_exit(fn -> ProjectView.close(view) end)

    pid =
      start_supervised!(
        {Native,
         subscriber: self(),
         model_selection: ModelSelectionFixture.selection(),
         project_root: launch_dir,
         project_view: view,
         tools: [],
         skip_api_key_env: true}
      )

    assert {:ok, %{project_root: session_root}} = Native.get_state(pid)
    assert session_root == project
    assert Native.project_view(pid) == view

    assert read_file(session_root, Native.project_view(pid), "notes.md") == "project notes\n"
  end

  @spec read_file(String.t(), ProjectView.t(), String.t()) :: String.t()
  defp read_file(root, view, path) do
    retained = RetainedContextFixture.new(root, "native-project-root")

    context =
      ToolContext.new(
        project_root: root,
        project_view: view,
        artifact_store: retained.artifact_store
      )

    scoped =
      ToolContext.for_tool_call(context, context.artifact_store, "native-project-root", "call-1")

    spec = Enum.find(Tools.all(), &(&1.name == "read_file"))
    assert {:ok, %Output{view: text}} = Spec.build_callback(spec, scoped).(%{"path" => path})
    text
  end
end
