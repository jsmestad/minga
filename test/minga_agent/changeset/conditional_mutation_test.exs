defmodule MingaAgent.Changeset.ConditionalMutationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.FileMutation
  alias MingaAgent.Changeset
  alias MingaAgent.Changeset.Server

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.write!(Path.join(root, "file.txt"), "one two three\n")
    cs = start_supervised!({Server, project_root: root})
    %{cs: cs, root: root, identity: {:changeset, Path.join(root, "file.txt")}}
  end

  test "commits a complete batch with one revision and one undo entry", context do
    %{cs: cs, identity: identity} = context
    {:ok, bytes, version} = Changeset.read_file_with_version(cs, "file.txt")
    expected = FileMutation.revision(bytes, version, identity)

    assert {:ok, %FileMutation.Receipt{before: ^bytes, after: "ONE two THREE\n"}} =
             Changeset.conditional_mutate(
               cs,
               "file.txt",
               expected,
               {:edit, [{"one", "ONE"}, {"three", "THREE"}]},
               identity
             )

    assert {:ok, "ONE two THREE\n", next} = Changeset.read_file_with_version(cs, "file.txt")
    assert next == version + 1
    assert :ok = Changeset.undo(cs, "file.txt")
    assert {:ok, ^bytes} = Changeset.read_file(cs, "file.txt")
    assert {:error, :nothing_to_undo} = Changeset.undo(cs, "file.txt")
  end

  test "staging a resolution moves the writer's bytes past independent disk additions",
       %{cs: cs, root: root} do
    file = "file.txt"
    File.write!(Path.join(root, file), "prefix\nheader\nold\nsame\n")
    assert :ok = Changeset.capture_original(cs, file)
    source = Minga.Buffer.EditSource.minga("draft-task", "step")
    draft = {"header\nα\nsame\n", [{7, 2, {source, 75}}]}
    assert :ok = Changeset.stage_fork_resolution(cs, file, "header\nold\nsame\n", draft)

    assert {[%{content: "prefix\nheader\nα\nsame\n", origins: [{14, 2, {^source, 75}}]}], %{}} =
             Changeset.staged_drafts(cs)
  end

  test "restoring and undoing a closed-file edit preserves its original attribution", %{
    cs: cs,
    identity: identity
  } do
    file = "file.txt"
    {:ok, bytes, version} = Changeset.read_file_with_version(cs, file)
    a = Minga.Buffer.EditSource.minga("a", "first")
    b = Minga.Buffer.EditSource.minga("b", "second")
    expected = FileMutation.revision(bytes, version, identity)

    assert {:ok, _} =
             Changeset.conditional_mutate(
               cs,
               file,
               expected,
               {:edit, [{"one", "ONE"}]},
               identity,
               a
             )

    assert {[%{content: "ONE two three\n", origins: [{0, 3, {^a, time}}]} = draft], %{}} =
             Changeset.staged_drafts(cs)

    assert :ok = Changeset.undo(cs, file)
    assert :ok = Changeset.restore_draft(cs, draft)
    {:ok, bytes, version} = Changeset.read_file_with_version(cs, file)
    expected = FileMutation.revision(bytes, version, identity)

    assert {:ok, _} =
             Changeset.conditional_mutate(cs, file, expected, {:edit, [{"N", "β"}]}, identity, b)

    assert {[
              %{
                content: "OβE two three\n",
                origins: [{0, 1, {^a, ^time}}, {1, 2, {^b, _}}, {3, 1, {^a, ^time}}]
              }
            ], %{}} = Changeset.staged_drafts(cs)

    assert :ok = Changeset.undo(cs, file)
    assert {[^draft], %{}} = Changeset.staged_drafts(cs)
  end

  test "rejects a failed middle edit and stale delete without any state changes", context do
    %{cs: cs, identity: identity} = context
    {:ok, bytes, version} = Changeset.read_file_with_version(cs, "file.txt")
    expected = FileMutation.revision(bytes, version, identity)
    before = :sys.get_state(cs)

    assert {:error, {:edit_failed, 2, :not_found}} =
             Changeset.conditional_mutate(
               cs,
               "file.txt",
               expected,
               {:edit, [{"one", "ONE"}, {"missing", "no"}, {"three", "THREE"}]},
               identity
             )

    assert :sys.get_state(cs) == before
    assert :ok = Changeset.write_file(cs, "file.txt", "human\n")
    changed = :sys.get_state(cs)

    assert {:error, :stale_revision} =
             Changeset.conditional_mutate(cs, "file.txt", expected, :delete, identity)

    assert :sys.get_state(cs) == changed
    assert {:ok, "human\n"} = Changeset.read_file(cs, "file.txt")
  end

  test "serializes competing commits against the same revision", %{cs: cs, identity: identity} do
    {:ok, bytes, version} = Changeset.read_file_with_version(cs, "file.txt")
    expected = FileMutation.revision(bytes, version, identity)

    results =
      for content <- ["first", "second"] do
        Task.async(fn ->
          Changeset.conditional_mutate(cs, "file.txt", expected, {:replace, content}, identity)
        end)
      end
      |> Enum.map(&Task.await/1)

    assert [
             {:error, :stale_revision},
             {:ok, %FileMutation.Receipt{before: ^bytes, after: winner}}
           ] =
             Enum.sort(results)

    assert {:ok, ^winner, next} = Changeset.read_file_with_version(cs, "file.txt")
    assert next == version + 1
    assert :ok = Changeset.undo(cs, "file.txt")
    assert {:ok, ^bytes} = Changeset.read_file(cs, "file.txt")
  end

  test "creation requires absence and preserves a target created before dispatch", %{
    cs: cs,
    root: root
  } do
    identity = {:changeset, Path.join(root, "new.txt")}
    File.write!(Path.join(root, "new.txt"), "human")
    before = :sys.get_state(cs)

    assert {:error, :already_exists} =
             Changeset.conditional_mutate(cs, "new.txt", :absent, {:create, "agent"}, identity)

    assert :sys.get_state(cs) == before

    assert {:ok, %FileMutation.Receipt{before: :absent, after: "new"}} =
             Changeset.conditional_mutate(cs, "other.txt", :absent, {:create, "new"}, identity)

    assert {:ok, "new"} = Changeset.read_file(cs, "other.txt")
    refute File.exists?(Path.join(root, "other.txt"))
  end

  test "failed content and deletion commits preserve logical state and previous overlay bytes",
       context do
    %{cs: cs, identity: identity} = context
    assert :ok = Changeset.write_file(cs, "file.txt", "draft")
    overlay = Changeset.overlay_path(cs)
    marker = Path.join(overlay, "file.txt.__changeset_deleted__")
    File.mkdir!(marker)
    {:ok, bytes, version} = Changeset.read_file_with_version(cs, "file.txt")
    expected = FileMutation.revision(bytes, version, identity)
    before = :sys.get_state(cs)

    for operation <- [{:replace, "replacement"}, :delete] do
      assert {:error, :invalid_overlay_target} =
               Changeset.conditional_mutate(cs, "file.txt", expected, operation, identity)

      assert :sys.get_state(cs) == before
      assert File.read!(Path.join(overlay, "file.txt")) == "draft"
    end
  end

  test "publication preserves newer disk content after a conditional commit", context do
    %{cs: cs, identity: identity, root: root} = context
    {:ok, bytes, version} = Changeset.read_file_with_version(cs, "file.txt")
    expected = FileMutation.revision(bytes, version, identity)

    assert {:ok, _receipt} =
             Changeset.conditional_mutate(
               cs,
               "file.txt",
               expected,
               {:replace, "agent\n"},
               identity
             )

    File.write!(Path.join(root, "file.txt"), "human\n")
    assert {:conflict, _} = Changeset.merge(cs)
    assert File.read!(Path.join(root, "file.txt")) == "human\n"
    assert {:ok, "agent\n"} = Changeset.read_file(cs, "file.txt")
  end

  test "fork deletion publication uses its retained baseline and preserves conflicts", %{
    cs: cs,
    root: root
  } do
    assert :ok = Changeset.capture_original(cs, "file.txt")
    File.write!(Path.join(root, "file.txt"), "human\n")
    assert {:conflict, _} = Changeset.publish_deletion(cs, "file.txt")
    assert File.read!(Path.join(root, "file.txt")) == "human\n"
  end

  test "failed publication preserves real project and overlay bytes at every writer stage", %{
    root: root
  } do
    path = Path.join(root, "file.txt")
    original = File.read!(path)
    File.chmod!(path, 0o755)

    for stage <- [:write, :metadata, :flush, :rename] do
      cs =
        start_supervised!(
          {Server,
           project_root: root,
           publication_file_system: Minga.Buffer.ControllableFileSystem,
           publication_opts: [fail_at: stage]},
          id: stage
        )

      identity = {:changeset, path}
      {:ok, ^original, version} = Changeset.read_file_with_version(cs, "file.txt")
      expected = FileMutation.revision(original, version, identity)

      assert {:ok, _receipt} =
               Changeset.conditional_mutate(
                 cs,
                 "file.txt",
                 expected,
                 {:replace, "draft"},
                 identity
               )

      before = :sys.get_state(cs)
      assert {:conflict, details} = Changeset.merge(cs)
      assert {:error, "file.txt", {:injected, stage}} in details.results
      assert :sys.get_state(cs) == before
      assert File.read!(path) == original
      assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o755
      assert File.read!(Path.join(Changeset.overlay_path(cs), "file.txt")) == "draft"
      refute Enum.any?(File.ls!(root), &String.contains?(&1, ".minga-save-"))
    end
  end

  test "publication waits for the owner instead of timing out before a later disk commit", %{
    cs: cs,
    root: root,
    identity: identity
  } do
    {:ok, original, version} = Changeset.read_file_with_version(cs, "file.txt")
    expected = FileMutation.revision(original, version, identity)

    assert {:ok, _receipt} =
             Changeset.conditional_mutate(
               cs,
               "file.txt",
               expected,
               {:replace, "published"},
               identity
             )

    trace = :trace.session_create(:publication_wait, self(), [])
    assert 1 = :trace.function(trace, {GenServer, :call, 3}, true, [:local])
    :ok = :sys.suspend(cs, :infinity)

    task =
      Task.async(fn ->
        assert 1 = :trace.process(trace, self(), true, [:call])
        Changeset.merge(cs)
      end)

    try do
      # Observe the actual call deadline instead of waiting out the default timeout.
      pid = task.pid

      receive do
        {:trace, ^pid, :call, {GenServer, :call, [^cs, :merge, timeout]}} ->
          assert timeout == :infinity
      end

      assert File.read!(Path.join(root, "file.txt")) == original
    after
      :sys.resume(cs, :infinity)
      :trace.session_destroy(trace)
    end

    assert Task.await(task, :infinity) == :ok
    assert File.read!(Path.join(root, "file.txt")) == "published"
  end

  test "publication prunes successful files but retains a failed file for review", %{root: root} do
    File.write!(Path.join(root, "remove.txt"), "remove")

    cs =
      start_supervised!(
        {Server,
         project_root: root,
         publication_file_system: Minga.Buffer.ControllableFileSystem,
         publication_opts: [fail_at: :flush]},
        id: :partial_publication
      )

    assert :ok = Changeset.write_file(cs, "file.txt", "draft")
    assert :ok = Changeset.delete_file(cs, "remove.txt")
    assert {:conflict, details} = Changeset.merge(cs)
    assert {:error, "file.txt", {:injected, :flush}} in details.results
    assert {:ok, "remove.txt", :deleted} in details.results
    assert Changeset.modified_files(cs) == %{modified: ["file.txt"], deleted: []}
    assert File.read!(Path.join(root, "file.txt")) == "one two three\n"
    assert File.read!(Path.join(Changeset.overlay_path(cs), "file.txt")) == "draft"
    refute File.exists?(Path.join(root, "remove.txt"))
  end
end
