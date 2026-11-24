defmodule MingaAgent.Tool.ContextTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.FileMutation
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.ProjectView.UnavailableBackend
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Invocation

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

  test "for_tool_call derives the stable delivery capture key" do
    context = Context.new(project_root: "/tmp/project")

    assert %Context{
             artifact_store: store,
             capture_key: {:delivery, "checkpoint-1", "tool-call-2"}
           } = Context.for_tool_call(context, self(), "checkpoint-1", "tool-call-2")

    assert store == self()
    assert context.capture_key == nil
  end

  describe "a bound session invocation attributes its edits to Minga's task and step" do
    test "an edit of an open buffer records the author key", %{tmp_dir: root} do
      path = Path.join(root, "open.txt")
      File.write!(path, "one\ntwo\n")
      buffer = start_supervised!({Minga.Buffer.Process, file_path: path})

      context =
        [project_root: root]
        |> Context.new()
        |> Context.bind_session_invocation(self(), invocation("call-4"), "task-9")

      assert context.session_id == "task-9"
      {content, version} = Minga.Buffer.content_with_version(buffer)
      expected = FileMutation.revision(content, version, {:buffer, path})

      assert {:ok, _receipt} =
               Context.conditional_mutate(context, path, expected, {:replace, "one\n2\n"})

      assert Minga.Buffer.Process.last_undo_source(buffer) == {:minga, "task-9", "call-4"}
    end

    test "a staged edit of an open buffer is published under the author key", %{tmp_dir: root} do
      path = Path.join(root, "staged.txt")
      File.write!(path, "one\ntwo\n")
      buffer = start_supervised!({Minga.Buffer.Process, file_path: path})
      {:ok, view} = ProjectView.overlay(root)

      context =
        [project_root: root, project_view: view]
        |> Context.new()
        |> Context.bind_session_invocation(self(), invocation("call-5"), "task-9")

      {:ok, source} = ProjectView.resolve_source(view, "staged.txt")
      expected = FileMutation.revision("one\ntwo\n", nil, {:project_view, source.source_id})

      assert {:ok, _receipt} =
               Context.conditional_mutate(context, path, expected, {:replace, "1\ntwo\n"})

      assert Minga.Buffer.content(buffer) == "one\ntwo\n"
      assert :ok = ProjectView.promote(view, :project_root)
      assert Minga.Buffer.content(buffer) == "1\ntwo\n"
      assert Minga.Buffer.Process.last_undo_source(buffer) == {:minga, "task-9", "call-5"}
      assert :ok = ProjectView.close(view)
    end
  end

  defp invocation(call_id) do
    %Invocation{
      request_id: "request-1",
      checkpoint_id: "checkpoint-1",
      call_id: call_id,
      name: "edit_file",
      arguments: %{}
    }
  end
end
