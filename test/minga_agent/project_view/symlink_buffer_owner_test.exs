defmodule MingaAgent.ProjectView.SymlinkBufferOwnerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Fork
  alias MingaAgent.BufferForkStore
  alias MingaAgent.ProjectView
  alias MingaAgent.Test.RetainedContextFixture
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Revision
  alias MingaAgent.Tool.Spec
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, "lib"))
    real_path = Path.join(root, "lib/real.ex")
    File.write!(real_path, "saved\n")
    File.ln_s!("real.ex", Path.join(root, "lib/link.ex"))
    File.ln_s!("lib", Path.join(root, "linked"))

    {:ok, view} = ProjectView.overlay(root)
    on_exit(fn -> ProjectView.close(view) end)
    retained = RetainedContextFixture.new(root, "symlink-owner")

    context =
      Context.new(project_root: root, project_view: view, artifact_store: retained.artifact_store)

    %{root: root, real_path: real_path, view: view, context: context}
  end

  for {kind, opened} <- [final: "lib/link.ex", directory: "linked/real.ex"] do
    @opened opened

    test "write_file to a file open through a #{kind} symlink is staged in that buffer's fork",
         ctx do
      buffer = open_with_unsaved_edit(ctx.root, @opened)

      assert {:ok, _} =
               call(ctx.context, "write_file", %{
                 "path" => @opened,
                 "mode" => "replace",
                 "content" => "agent\n",
                 "expected_revision" => full_revision(ctx.context, @opened)
               })

      assert {:ok, %{owner: {:fork, fork}}} = ProjectView.resolve_source(ctx.view, "lib/real.ex")
      assert Fork.content(fork) == "agent\n"
      assert Buffer.content(buffer) == "saved\nunsaved\n"
      assert File.read!(ctx.real_path) == "saved\n"

      assert :ok = ProjectView.promote(ctx.view, :project_root)
      assert Buffer.content(buffer) == "agent\n"
    end

    test "edit_file to a file open through a #{kind} symlink edits the buffer's unsaved content",
         ctx do
      buffer = open_with_unsaved_edit(ctx.root, @opened)

      assert {:ok, _} =
               call(ctx.context, "edit_file", %{
                 "path" => "lib/real.ex",
                 "expected_revision" => full_revision(ctx.context, "lib/real.ex"),
                 "edits" => [%{"old_text" => "unsaved", "new_text" => "edited"}]
               })

      assert {:ok, %{owner: {:fork, fork}}} = ProjectView.resolve_source(ctx.view, "lib/real.ex")
      assert Fork.content(fork) == "saved\nedited\n"
      assert Buffer.content(buffer) == "saved\nunsaved\n"
      assert File.read!(ctx.real_path) == "saved\n"
    end
  end

  test "a file open by its real path and by a symlink path has one staging owner", ctx do
    by_link = open_with_unsaved_edit(ctx.root, "lib/link.ex")
    by_real = start_supervised!({Buffer.Process, file_path: ctx.real_path}, id: :by_real)

    for path <- ["lib/link.ex", "linked/real.ex", "lib/real.ex"] do
      assert {:ok, _} =
               call(ctx.context, "write_file", %{
                 "path" => path,
                 "mode" => "replace",
                 "content" => "agent via #{path}\n",
                 "expected_revision" => full_revision(ctx.context, path)
               })
    end

    assert {:ok, %{owner: {:fork, fork}} = source} =
             ProjectView.resolve_source(ctx.view, "lib/real.ex")

    assert Fork.content(fork) == "agent via lib/real.ex\n"
    assert {:ok, [%{path: "lib/real.ex"}]} = ProjectView.diff(ctx.view)
    assert {:ok, ^source} = ProjectView.resolve_source(ctx.view, "lib/real.ex")
    assert Buffer.content(by_link) == "saved\nunsaved\n"
    assert Buffer.content(by_real) == "saved\n"
  end

  test "without a project view, edit_file reaches a buffer opened through a symlink", ctx do
    buffer = open_with_unsaved_edit(ctx.root, "lib/link.ex")
    store = start_supervised!(BufferForkStore)
    artifact_store = RetainedContextFixture.new(ctx.root, "symlink-owner-direct").artifact_store

    fork_context =
      Context.new(project_root: ctx.root, artifact_store: artifact_store, fork_store: store)

    assert {:ok, _} = edit_unsaved(fork_context, "via fork")
    assert Fork.content(BufferForkStore.get(store, ctx.real_path)) == "saved\nvia fork\n"
    assert Buffer.content(buffer) == "saved\nunsaved\n"

    buffer_context = Context.new(project_root: ctx.root, artifact_store: artifact_store)

    assert {:ok, _} = edit_unsaved(buffer_context, "via buffer")
    assert Buffer.content(buffer) == "saved\nvia buffer\n"
  end

  @spec edit_unsaved(Context.t(), String.t()) :: term()
  defp edit_unsaved(context, replacement) do
    call(context, "edit_file", %{
      "path" => "lib/real.ex",
      "expected_revision" => full_revision(context, "lib/real.ex"),
      "edits" => [%{"old_text" => "unsaved", "new_text" => replacement}]
    })
  end

  @spec open_with_unsaved_edit(String.t(), String.t()) :: pid()
  defp open_with_unsaved_edit(root, opened) do
    buffer = start_supervised!({Buffer.Process, file_path: Path.join(root, opened)})
    assert :ok = Buffer.replace_content(buffer, "saved\nunsaved\n", :user)
    buffer
  end

  @spec full_revision(Context.t(), String.t()) :: String.t()
  defp full_revision(context, path) do
    assert {:ok, %Output{} = output} = call(context, "read_file", %{"path" => path})
    assert Revision.full_source?(output.revision)
    Revision.token(output.revision)
  end

  @spec call(Context.t(), String.t(), map()) :: term()
  defp call(context, name, args) do
    spec = Enum.find(Tools.all(), &(&1.name == name))
    call_id = "call-#{System.unique_integer([:positive])}"
    scoped = Context.for_tool_call(context, context.artifact_store, "symlink-owner", call_id)
    Spec.build_callback(spec, scoped).(args)
  end
end
