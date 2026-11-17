defmodule MingaAgent.Tools.DeleteFileTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.Test.RetainedContextFixture
  alias MingaAgent.Tool.Context
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Revision
  alias MingaAgent.Tool.Spec
  alias MingaAgent.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: root} = tags do
    path = Path.join(root, "delete.txt")
    File.write!(path, "gone soon")
    retained = RetainedContextFixture.new(root, "delete-file")

    opts =
      case Map.get(tags, :route, :changeset) do
        :changeset ->
          [changeset: start_supervised!({Changeset.Server, project_root: root})]

        :overlay ->
          {:ok, view} = ProjectView.overlay(root)
          on_exit(fn -> ProjectView.close(view) end)
          [project_view: view]
      end

    context = Context.new([project_root: root, artifact_store: retained.artifact_store] ++ opts)
    %{context: context, path: path}
  end

  for route <- [:changeset, :overlay] do
    @tag route: route
    test "deletes only the matching revision in the owned #{route} view", ctx do
      revision = full_revision(ctx.context)

      assert {:ok, _} =
               call(ctx.context, "delete_file", %{
                 "path" => "delete.txt",
                 "expected_revision" => revision
               })

      assert {:error, _} = Context.read_file(ctx.context, ctx.path)
      assert File.read!(ctx.path) == "gone soon"

      assert {:error, _} =
               call(ctx.context, "delete_file", %{
                 "path" => "delete.txt",
                 "expected_revision" => revision
               })
    end

    @tag route: route
    test "stale #{route} deletion cannot remove newer content", ctx do
      revision = full_revision(ctx.context)

      assert {:ok, _} =
               call(ctx.context, "write_file", %{
                 "path" => "delete.txt",
                 "mode" => "replace",
                 "content" => "newer content",
                 "expected_revision" => revision
               })

      newer = full_revision(ctx.context)

      assert {:error, message} =
               call(ctx.context, "delete_file", %{
                 "path" => "delete.txt",
                 "expected_revision" => revision
               })

      assert message =~ "stale revision"
      assert full_revision(ctx.context) == newer
      assert {:ok, "newer content"} = Context.read_file(ctx.context, ctx.path)
      assert File.read!(ctx.path) == "gone soon"
    end
  end

  test "deletion requires a revision and rejects absent", ctx do
    for args <- [
          %{"path" => "delete.txt"},
          %{"path" => "delete.txt", "expected_revision" => "absent"}
        ] do
      assert {:error, _} = call(ctx.context, "delete_file", args)
    end

    assert {:ok, "gone soon"} = Context.read_file(ctx.context, ctx.path)
    assert File.read!(ctx.path) == "gone soon"
  end

  test "deletion has no unchecked filesystem fallback", ctx do
    context =
      Context.new(
        project_root: ctx.context.project_root,
        artifact_store: ctx.context.artifact_store
      )

    assert {:error, _} =
             call(context, "delete_file", %{
               "path" => "delete.txt",
               "expected_revision" => full_revision(ctx.context)
             })

    assert File.read!(ctx.path) == "gone soon"
  end

  test "an open direct buffer is not silently deleted on disk", ctx do
    buffer = start_supervised!({Buffer.Process, file_path: ctx.path})

    context =
      Context.new(
        project_root: ctx.context.project_root,
        artifact_store: ctx.context.artifact_store
      )

    assert {:error, _} =
             call(context, "delete_file", %{
               "path" => "delete.txt",
               "expected_revision" => full_revision(context)
             })

    assert Buffer.content(buffer) == "gone soon"
    assert File.read!(ctx.path) == "gone soon"
  end

  defp full_revision(context) do
    assert {:ok, %Output{} = output} = call(context, "read_file", %{"path" => "delete.txt"})
    assert Revision.full_source?(output.revision)
    Revision.token(output.revision)
  end

  defp call(context, name, args) do
    spec = Enum.find(Tools.all(), &(&1.name == name))

    scoped =
      Context.for_tool_call(
        context,
        context.artifact_store,
        "delete-file",
        "call-#{System.unique_integer([:positive])}"
      )

    Spec.build_callback(spec, scoped).(args)
  end
end
