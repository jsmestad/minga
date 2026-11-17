defmodule MingaAgent.Tools.EditFileTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias MingaAgent.BufferForkStore
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
    content = Map.get(tags, :content, "α one\n  two\nthree")
    path = Path.join(root, "code.txt")
    File.write!(path, content)
    route = Map.get(tags, :route, :changeset)
    retained = RetainedContextFixture.new(root, "edit-file")
    opts = route_options(route, root, path)

    context =
      Context.new([project_root: root, artifact_store: retained.artifact_store] ++ opts)

    %{context: context, path: path, original: content, route: route}
  end

  for route <- [:buffer, :fork, :changeset, :direct, :overlay] do
    @tag route: route
    test "commits one ordered exact batch through #{route}", ctx do
      revision = full_revision(ctx.context)

      assert {:ok, message} =
               edit(ctx.context, revision, [
                 %{"old_text" => "α one\n", "new_text" => "日本語 first\n"},
                 %{"old_text" => "  two", "new_text" => "    second"}
               ])

      assert is_binary(message)
      assert read(ctx.context).view =~ "日本語 first\n    second\nthree"
      refute full_revision(ctx.context) == revision

      if ctx.route != :direct do
        assert File.read!(ctx.path) == ctx.original
      end

      if ctx.route == :fork do
        {:ok, parent} = Buffer.pid_for_path(ctx.path)
        assert Buffer.content(parent) == ctx.original
      end
    end

    @tag route: route
    test "rejects the entire #{route} batch when a later edit fails", ctx do
      revision = full_revision(ctx.context)

      assert {:error, message} =
               edit(ctx.context, revision, [
                 %{"old_text" => "one", "new_text" => "ONE"},
                 %{"old_text" => "missing", "new_text" => "replacement"},
                 %{"old_text" => "three", "new_text" => "THREE"}
               ])

      assert message =~ "edit 2"
      assert full_revision(ctx.context) == revision
      assert read(ctx.context).view =~ ctx.original
      assert File.read!(ctx.path) == ctx.original
    end

    @tag route: route
    test "rejects stale #{route} revisions without altering the newer content", ctx do
      revision = full_revision(ctx.context)
      assert {:ok, _} = edit(ctx.context, revision, [%{"old_text" => "one", "new_text" => "ONE"}])
      newer = full_revision(ctx.context)

      assert {:error, message} =
               edit(ctx.context, revision, [%{"old_text" => "two", "new_text" => "TWO"}])

      assert message =~ "stale revision"
      assert full_revision(ctx.context) == newer
      assert read(ctx.context).view =~ "α ONE\n  two\nthree"
    end
  end

  for {name, content, edits, index} <- [
        {"ambiguous", "one one", [%{"old_text" => "one", "new_text" => "ONE"}], 1},
        {"overlapping occurrences", "aaa", [%{"old_text" => "aa", "new_text" => "A"}], 1},
        {"empty old text", "one", [%{"old_text" => "", "new_text" => "ONE"}], 1},
        {"invalid edit", "one", [%{"old_text" => "one", "new_text" => 42}], 1},
        {"touching replacement bytes", "one two",
         [%{"old_text" => "one", "new_text" => "ONE"}, %{"old_text" => "ONE", "new_text" => "x"}],
         2},
        {"newly ambiguous sequential match", "one two",
         [%{"old_text" => "one", "new_text" => "two"}, %{"old_text" => "two", "new_text" => "x"}],
         2}
      ] do
    @tag content: content, edits: edits, index: index
    test "rejects #{name} without any commit", ctx do
      revision = full_revision(ctx.context)
      assert {:error, message} = edit(ctx.context, revision, ctx.edits)
      assert message =~ "edit #{ctx.index}"
      assert full_revision(ctx.context) == revision
      assert File.read!(ctx.path) == ctx.original
    end
  end

  test "requires a nonempty batch and a full-source revision", ctx do
    revision = full_revision(ctx.context)
    assert {:error, _} = edit(ctx.context, revision, [])
    assert {:error, _} = edit(ctx.context, nil, [%{"old_text" => "one", "new_text" => "ONE"}])

    assert {:ok, %Output{} = partial} =
             call(ctx.context, "read_file", %{"path" => "code.txt", "limit" => 1})

    refute Revision.full_source?(partial.revision)

    assert {:error, _} =
             edit(ctx.context, Revision.token(partial.revision), [
               %{"old_text" => "one", "new_text" => "ONE"}
             ])

    assert full_revision(ctx.context) == revision
    assert File.read!(ctx.path) == ctx.original
  end

  test "old single-edit arguments are not an alternate unchecked API", ctx do
    revision = full_revision(ctx.context)

    for legacy <- [
          %{"old_text" => "one", "new_text" => "ONE"},
          %{"find" => "one", "replace" => "ONE"}
        ] do
      args = Map.merge(legacy, %{"path" => "code.txt", "expected_revision" => revision})
      assert {:error, _} = call(ctx.context, "edit_file", args)
    end

    assert full_revision(ctx.context) == revision
    assert File.read!(ctx.path) == ctx.original
  end

  test "a missing target is not created by edit_file", ctx do
    assert {:error, _} =
             call(ctx.context, "edit_file", %{
               "path" => "missing.txt",
               "expected_revision" => full_revision(ctx.context),
               "edits" => [%{"old_text" => "one", "new_text" => "ONE"}]
             })

    assert {:error, _} = Changeset.read_file(ctx.context.router_context.changeset, "missing.txt")
    refute File.exists?(Path.join(ctx.context.project_root, "missing.txt"))
  end

  @tag route: :buffer
  test "one successful batch is one buffer undo entry", ctx do
    {:ok, buffer} = Buffer.pid_for_path(ctx.path)
    revision = full_revision(ctx.context)

    assert {:ok, _} =
             edit(ctx.context, revision, [
               %{"old_text" => "one", "new_text" => "ONE"},
               %{"old_text" => "three", "new_text" => "THREE"}
             ])

    assert Buffer.dirty?(buffer)
    Buffer.undo(buffer)
    assert Buffer.content(buffer) == ctx.original
    assert File.read!(ctx.path) == ctx.original
  end

  test "one successful batch is one changeset undo entry", ctx do
    assert {:ok, _} =
             edit(ctx.context, full_revision(ctx.context), [
               %{"old_text" => "one", "new_text" => "ONE"},
               %{"old_text" => "three", "new_text" => "THREE"}
             ])

    assert :ok = Changeset.undo(ctx.context.router_context.changeset, "code.txt")
    assert read(ctx.context).view =~ ctx.original
  end

  @tag route: :fork
  test "a dead fork owner cannot fall back to direct edits", ctx do
    revision = full_revision(ctx.context)
    store = ctx.context.router_context.fork_store
    ref = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^ref, :process, ^store, _}

    assert {:error, message} =
             edit(ctx.context, revision, [%{"old_text" => "one", "new_text" => "ONE"}])

    assert message =~ "fork_unavailable"
    {:ok, parent} = Buffer.pid_for_path(ctx.path)
    assert Buffer.content(parent) == ctx.original
    assert File.read!(ctx.path) == ctx.original
  end

  defp route_options(:buffer, _root, path) do
    start_supervised!({Buffer.Process, file_path: path})
    []
  end

  defp route_options(:fork, _root, path) do
    start_supervised!({Buffer.Process, file_path: path})
    [fork_store: start_supervised!(BufferForkStore)]
  end

  defp route_options(:changeset, root, _path),
    do: [changeset: start_supervised!({Changeset.Server, project_root: root})]

  defp route_options(route, root, _path) when route in [:direct, :overlay] do
    {:ok, view} = apply(ProjectView, route, [root])
    on_exit(fn -> ProjectView.close(view) end)
    [project_view: view]
  end

  defp edit(context, revision, edits) do
    call(context, "edit_file", %{
      "path" => "code.txt",
      "expected_revision" => revision,
      "edits" => edits
    })
  end

  defp full_revision(context) do
    output = read(context)
    assert Revision.full_source?(output.revision)
    Revision.token(output.revision)
  end

  defp read(context) do
    assert {:ok, %Output{} = output} = call(context, "read_file", %{"path" => "code.txt"})
    output
  end

  defp call(context, name, args) do
    spec = Enum.find(Tools.all(), &(&1.name == name))

    scoped =
      Context.for_tool_call(
        context,
        context.artifact_store,
        "edit-file",
        "call-#{System.unique_integer([:positive])}"
      )

    Spec.build_callback(spec, scoped).(args)
  end
end
