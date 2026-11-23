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

  for route <- [:buffer, :fork, :changeset, :direct, :overlay] do
    for {content, appended, expected} <- [
          {"one\ntwo", "Checked: on device", "one\ntwo\nChecked: on device"},
          {"one\ntwo\n", "Checked: on device\n", "one\ntwo\nChecked: on device\n"},
          {"one\ntwo", "\nChecked: on device", "one\ntwo\nChecked: on device"},
          {"", "Checked: on device", "Checked: on device"}
        ] do
      @tag route: route, content: content, appended: appended, expected: expected
      test "empty old_text appends #{inspect(appended)} to #{inspect(content)} through #{route}",
           ctx do
        revision = full_revision(ctx.context)

        assert {:ok, _message} =
                 edit(ctx.context, revision, [%{"old_text" => "", "new_text" => ctx.appended}])

        assert {:ok, %Output{} = output} =
                 call(ctx.context, "read_file", %{"path" => "code.txt"})

        assert output.view =~ ctx.expected
        refute full_revision(ctx.context) == revision
      end
    end

    @tag route: route
    test "an append through #{route} still requires the current revision", ctx do
      revision = full_revision(ctx.context)
      assert {:ok, _} = edit(ctx.context, revision, [%{"old_text" => "one", "new_text" => "ONE"}])
      newer = full_revision(ctx.context)

      assert {:error, message} =
               edit(ctx.context, revision, [%{"old_text" => "", "new_text" => "late"}])

      assert message =~ "stale revision"
      assert full_revision(ctx.context) == newer
      refute read(ctx.context).view =~ "late"
    end
  end

  # Buffer and fork routes own only open buffers, so a missing path has no editable view there.
  for route <- [:changeset, :direct, :overlay] do
    @tag route: route
    test "an append through #{route} cannot create a missing file", ctx do
      assert {:error, message} =
               call(ctx.context, "edit_file", %{
                 "path" => "missing.txt",
                 "expected_revision" => "absent",
                 "edits" => [%{"old_text" => "", "new_text" => "Checked: on device"}]
               })

      assert message =~ "does not exist"
      assert message =~ "write_file"
      refute File.exists?(Path.join(ctx.context.project_root, "missing.txt"))
    end
  end

  @tag content: "one\ntwo"
  test "an append batch applies in order with replacements and protects the appended bytes",
       ctx do
    revision = full_revision(ctx.context)

    assert {:ok, _} =
             edit(ctx.context, revision, [
               %{"old_text" => "one", "new_text" => "ONE"},
               %{"old_text" => "", "new_text" => "three"},
               %{"old_text" => "", "new_text" => "four\n"}
             ])

    assert read(ctx.context).view =~ "ONE\ntwo\nthree\nfour\n"

    revision = full_revision(ctx.context)

    assert {:error, message} =
             edit(ctx.context, revision, [
               %{"old_text" => "", "new_text" => "five"},
               %{"old_text" => "four\nfive", "new_text" => "x"}
             ])

    assert message =~ "edit 2"
    assert message =~ "overlapping_edit"
    assert full_revision(ctx.context) == revision
  end

  test "an append with empty new_text is rejected as a no-op edit", ctx do
    revision = full_revision(ctx.context)

    assert {:error, message} =
             edit(ctx.context, revision, [%{"old_text" => "", "new_text" => ""}])

    assert message =~ "edit 1"
    assert message =~ "both empty"
    assert full_revision(ctx.context) == revision
    assert File.read!(ctx.path) == ctx.original
  end

  test "the canonical schema accepts the append form and names a failing field" do
    spec = Enum.find(Tools.all(), &(&1.name == "edit_file"))
    old_text = spec.parameter_schema["properties"]["edits"]["items"]["properties"]["old_text"]

    refute Map.has_key?(old_text, "minLength")
    assert spec.description =~ "empty old_text appends"

    append = %{
      "path" => "code.txt",
      "expected_revision" => "revision",
      "edits" => [%{"old_text" => "", "new_text" => "Checked: on device"}]
    }

    assert {:ok, ^append} = Spec.validate_arguments(spec, append)

    # Every route's executor returns this message to the model as the tool error text.
    invalid = put_in(append, ["edits", Access.at(0), "old_text"], 1)
    assert {:error, %JSV.ValidationError{} = error} = Spec.validate_arguments(spec, invalid)
    assert Exception.message(error) =~ ~s(at: "#/edits/0/old_text")
  end

  for {name, content, edits, index} <- [
        {"ambiguous", "one one", [%{"old_text" => "one", "new_text" => "ONE"}], 1},
        {"overlapping occurrences", "aaa", [%{"old_text" => "aa", "new_text" => "A"}], 1},
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
