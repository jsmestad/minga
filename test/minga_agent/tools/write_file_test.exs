defmodule MingaAgent.Tools.WriteFileTest do
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
    path = Path.join(root, "existing.txt")
    File.write!(path, "original")
    retained = RetainedContextFixture.new(root, "write-file")

    opts =
      case Map.get(tags, :route, :changeset) do
        :changeset ->
          [changeset: start_supervised!({Changeset.Server, project_root: root})]

        :buffer ->
          start_supervised!({Buffer.Process, file_path: path})
          []

        route when route in [:direct, :overlay] ->
          {:ok, view} = apply(ProjectView, route, [root])
          on_exit(fn -> ProjectView.close(view) end)
          [project_view: view]
      end

    context = Context.new([project_root: root, artifact_store: retained.artifact_store] ++ opts)
    %{context: context, path: path}
  end

  for route <- [:changeset, :overlay, :direct] do
    @tag route: route
    test "explicit create through #{route} preserves Unicode, empty files, and nested paths",
         ctx do
      for {path, content} <- [{"a/b/unicode.txt", "Ελληνικά 日本語"}, {"empty.txt", ""}] do
        assert {:ok, _} =
                 call(ctx.context, "write_file", %{
                   "path" => path,
                   "mode" => "create",
                   "content" => content,
                   "expected_revision" => "absent"
                 })

        assert {:ok, %Output{} = output} = call(ctx.context, "read_file", %{"path" => path})

        assert {:ok, ^content} =
                 Context.read_file(ctx.context, Path.join(ctx.context.project_root, path))

        assert Revision.full_source?(output.revision)

        if ctx.context.router_context.changeset || route_is_overlay?(ctx.context) do
          refute File.exists?(Path.join(ctx.context.project_root, path))
        end
      end
    end

    @tag route: route
    test "#{route} rejects create over an existing file and replace with absent", ctx do
      for mode <- ["create", "replace"] do
        assert {:error, _} =
                 call(ctx.context, "write_file", %{
                   "path" => "existing.txt",
                   "mode" => mode,
                   "content" => "must not commit",
                   "expected_revision" => "absent"
                 })
      end

      assert File.read!(ctx.path) == "original"
      assert {:ok, output} = call(ctx.context, "read_file", %{"path" => "existing.txt"})
      assert output.view =~ "original"
    end
  end

  for route <- [:changeset, :overlay, :direct, :buffer] do
    @tag route: route
    test "replace through #{route} requires the current full read revision", ctx do
      revision = full_revision(ctx.context)

      args = %{
        "path" => "existing.txt",
        "mode" => "replace",
        "content" => "new",
        "expected_revision" => revision
      }

      assert {:ok, _} = call(ctx.context, "write_file", args)
      newer = full_revision(ctx.context)
      refute newer == revision

      assert {:error, message} = call(ctx.context, "write_file", %{args | "content" => "stale"})
      assert message =~ "stale revision"
      assert full_revision(ctx.context) == newer

      assert {:error, _} = call(ctx.context, "write_file", Map.delete(args, "mode"))
      assert {:error, _} = call(ctx.context, "write_file", Map.delete(args, "expected_revision"))
      assert full_revision(ctx.context) == newer
    end
  end

  test "replace cannot create a missing file", ctx do
    assert {:error, _} =
             call(ctx.context, "write_file", %{
               "path" => "missing.txt",
               "mode" => "replace",
               "content" => "new",
               "expected_revision" => full_revision(ctx.context)
             })

    refute File.exists?(Path.join(ctx.context.project_root, "missing.txt"))
    assert {:error, _} = Changeset.read_file(ctx.context.router_context.changeset, "missing.txt")
  end

  @tag route: :buffer
  test "replacement is undoable without writing the disk file", ctx do
    {:ok, buffer} = Buffer.pid_for_path(ctx.path)

    assert {:ok, _} =
             call(ctx.context, "write_file", %{
               "path" => "existing.txt",
               "mode" => "replace",
               "content" => "",
               "expected_revision" => full_revision(ctx.context)
             })

    assert Buffer.content(buffer) == ""
    assert Buffer.dirty?(buffer)
    assert File.read!(ctx.path) == "original"
    Buffer.undo(buffer)
    assert Buffer.content(buffer) == "original"
  end

  test "no editable route is not permission to write the filesystem", ctx do
    context =
      Context.new(
        project_root: ctx.context.project_root,
        artifact_store: ctx.context.artifact_store
      )

    assert {:error, _} =
             call(context, "write_file", %{
               "path" => "unchecked.txt",
               "mode" => "create",
               "content" => "unchecked",
               "expected_revision" => "absent"
             })

    refute File.exists?(Path.join(context.project_root, "unchecked.txt"))
  end

  defp route_is_overlay?(context) do
    case context.router_context.project_view do
      %ProjectView{} = view -> ProjectView.capabilities(view).isolation == :overlay
      nil -> false
    end
  end

  defp full_revision(context) do
    assert {:ok, %Output{} = output} = call(context, "read_file", %{"path" => "existing.txt"})
    assert Revision.full_source?(output.revision)
    Revision.token(output.revision)
  end

  defp call(context, name, args) do
    spec = Enum.find(Tools.all(), &(&1.name == name))

    scoped =
      Context.for_tool_call(
        context,
        context.artifact_store,
        "write-file",
        "call-#{System.unique_integer([:positive])}"
      )

    Spec.build_callback(spec, scoped).(args)
  end
end
