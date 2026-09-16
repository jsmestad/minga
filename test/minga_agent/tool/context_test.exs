defmodule MingaAgent.Tool.ContextTest do
  use ExUnit.Case, async: true

  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.ProjectView.UnavailableBackend
  alias MingaAgent.Tool.Context

  @moduletag :tmp_dir

  test "extension-facing accessors preserve successful simple-value contracts", %{tmp_dir: root} do
    working_dir = Path.join(root, "view")
    env = [{"ROUTED", "true"}]

    {:ok, view} =
      RecordingBackend.create(root, parent: self(), working_dir: working_dir, env: env)

    context = Context.new(project_root: root, project_view: view)

    assert Context.working_dir(context) == working_dir
    assert Context.command_env(context) == env
  end

  test "extension-facing accessors retain simple defaults when routing fails", %{tmp_dir: root} do
    {:ok, view} = UnavailableBackend.create(root, workspace_id: 7)
    context = Context.new(project_root: root, project_view: view)

    assert Context.working_dir(context) == nil
    assert Context.command_env(context) == []
  end
end
