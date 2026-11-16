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

    assert :ok =
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

    assert Enum.sort(results) == Enum.sort([:ok, {:error, :stale_revision}])
    assert {:ok, _, next} = Changeset.read_file_with_version(cs, "file.txt")
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

    assert :ok =
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

    assert :ok =
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

      assert :ok =
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

    assert :ok =
             Changeset.conditional_mutate(
               cs,
               "file.txt",
               expected,
               {:replace, "published"},
               identity
             )

    :ok = :sys.suspend(cs)
    caller = self()

    task =
      Task.async(fn ->
        send(caller, :publication_started)

        result =
          try do
            Changeset.merge(cs)
          catch
            :exit, reason -> {:error, reason}
          end

        send(caller, {:publication_completed, result})
        result
      end)

    try do
      assert_receive :publication_started
      refute_receive {:publication_completed, _}, 5_100
      assert File.read!(Path.join(root, "file.txt")) == original
    after
      :sys.resume(cs)
    end

    assert_receive {:publication_completed, :ok}, 1_000
    assert Task.await(task) == :ok
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
