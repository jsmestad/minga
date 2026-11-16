defmodule MingaAgent.ProjectView.ConditionalMutationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.FileMutation
  alias MingaAgent.BufferForkStore
  alias MingaAgent.ProjectView

  @moduletag :tmp_dir

  test "both backends own unopened edits, creation and deletion until reconciled publication", %{
    tmp_dir: root
  } do
    for {name, create} <- [direct: &ProjectView.direct/1, overlay: &ProjectView.overlay/1] do
      dir = Path.join(root, Atom.to_string(name))
      File.mkdir_p!(dir)
      path = Path.join(dir, "file.txt")
      File.write!(path, "original\n")
      {:ok, view} = create.(dir)
      token = revision(view, "file.txt", "original\n")

      assert :ok =
               ProjectView.conditional_mutate(
                 view,
                 "file.txt",
                 token,
                 {:edit, [{"original", "draft"}]}
               )

      assert {:ok, "draft\n"} = ProjectView.read_file(view, "file.txt")
      assert File.read!(path) == "original\n"

      assert {:error, :stale_revision} =
               ProjectView.conditional_mutate(view, "file.txt", token, :delete)

      assert :ok = ProjectView.conditional_mutate(view, "new.txt", :absent, {:create, "new"})

      assert {:error, :already_exists} =
               ProjectView.conditional_mutate(view, "new.txt", :absent, {:create, "other"})

      token = revision(view, "file.txt", "draft\n")
      assert :ok = ProjectView.conditional_mutate(view, "file.txt", token, :delete)
      assert {:error, _} = ProjectView.read_file(view, "file.txt")
      assert {:ok, entries} = ProjectView.diff(view)
      assert Enum.any?(entries, &(&1.path == "file.txt" and &1.kind == :deleted))
      assert :ok = ProjectView.promote(view, :project_root)
      refute File.exists?(path)
      assert File.read!(Path.join(dir, "new.txt")) == "new"
      assert :ok = ProjectView.close(view)
    end
  end

  test "both backends capture and conditionally edit unsaved open content in the actual fork", %{
    tmp_dir: root
  } do
    for {name, create} <- [direct: &ProjectView.direct/1, overlay: &ProjectView.overlay/1] do
      dir = Path.join(root, Atom.to_string(name))
      File.mkdir_p!(dir)
      path = Path.join(dir, "open.txt")
      File.write!(path, "disk\n")

      parent =
        start_supervised!({Minga.Buffer.Process, content: "unsaved\n", file_path: path}, id: name)

      assert :ok = Minga.Buffer.replace_content(parent, "unsaved\n", :user)
      {:ok, view} = create.(dir)
      assert {:ok, "unsaved\n"} = ProjectView.read_file(view, "open.txt")
      assert {:ok, %{owner: {:fork, fork}}} = ProjectView.resolve_source(view, "open.txt")
      token = revision(view, "open.txt", "unsaved\n")

      assert :ok =
               ProjectView.conditional_mutate(
                 view,
                 "open.txt",
                 token,
                 {:edit, [{"unsaved", "agent"}]}
               )

      assert Minga.Buffer.Fork.content(fork) == "agent\n"
      assert Minga.Buffer.content(parent) == "unsaved\n"
      assert File.read!(path) == "disk\n"

      assert {:error, {:edit_failed, 2, :not_found}} =
               ProjectView.conditional_mutate(
                 view,
                 "open.txt",
                 revision(view, "open.txt", "agent\n"),
                 {:edit, [{"agent", "partial"}, {"missing", "bad"}]}
               )

      assert {:ok, "agent\n"} = ProjectView.read_file(view, "open.txt")
      assert :ok = Minga.Buffer.Fork.undo(fork)
      assert {:ok, "unsaved\n"} = ProjectView.read_file(view, "open.txt")
      close_drafts(view)
    end
  end

  test "open deletion is isolated and publishes only while both parent and disk match", %{
    tmp_dir: root
  } do
    path = Path.join(root, "open.txt")
    File.write!(path, "original\n")
    parent = start_supervised!({Minga.Buffer.Process, content: "original\n", file_path: path})
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "open.txt", "original\n")
    assert :ok = ProjectView.conditional_mutate(view, "open.txt", token, :delete)
    assert {:error, :enoent} = ProjectView.read_file(view, "open.txt")
    assert File.read!(path) == "original\n"
    assert Minga.Buffer.content(parent) == "original\n"
    assert :ok = Minga.Buffer.replace_content(parent, "human\n", :user)
    assert {:conflict, _} = ProjectView.promote(view, :project_root)
    assert File.read!(path) == "original\n"
    assert {:error, :enoent} = ProjectView.read_file(view, "open.txt")
    assert :ok = Minga.Buffer.replace_content(parent, "original\n", :user)
    assert :ok = ProjectView.promote(view, :project_root)
    refute File.exists?(path)
    assert Minga.Buffer.content(parent) == "original\n"
    assert :ok = ProjectView.close(view)
  end

  test "disk human edit before fork publication is preserved and reported", %{tmp_dir: root} do
    path = Path.join(root, "open.txt")
    File.write!(path, "original\n")
    start_supervised!({Minga.Buffer.Process, content: "original\n", file_path: path})
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "open.txt", "original\n")
    File.write!(path, "human\n")
    assert :ok = ProjectView.conditional_mutate(view, "open.txt", token, {:replace, "agent\n"})
    assert {:conflict, _} = ProjectView.promote(view, :project_root)
    assert File.read!(path) == "human\n"
    close_drafts(view)
  end

  test "disk human edit before deletion publication retains the tombstoned fork", %{tmp_dir: root} do
    path = Path.join(root, "open.txt")
    File.write!(path, "original\n")
    start_supervised!({Minga.Buffer.Process, content: "original\n", file_path: path})
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "open.txt", "original\n")
    assert :ok = ProjectView.conditional_mutate(view, "open.txt", token, :delete)
    File.write!(path, "human\n")
    assert {:conflict, _} = ProjectView.promote(view, :project_root)
    assert File.read!(path) == "human\n"
    assert {:error, :enoent} = ProjectView.read_file(view, "open.txt")
    close_drafts(view)
  end

  test "unavailable source never falls back to writing disk", %{tmp_dir: root} do
    path = Path.join(root, "file.txt")
    File.write!(path, "original")
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "file.txt", "original")
    monitor = Process.monitor(view.ref.changeset)
    Process.exit(view.ref.changeset, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, _}

    assert {:error, _} =
             ProjectView.conditional_mutate(view, "file.txt", token, {:replace, "agent"})

    assert File.read!(path) == "original"
    BufferForkStore.stop(view.ref.fork_store)
  end

  test "reading an unsaved open file does not publish human bytes without an agent edit", %{
    tmp_dir: root
  } do
    path = Path.join(root, "open.txt")
    File.write!(path, "disk\n")
    parent = start_supervised!({Minga.Buffer.Process, content: "disk\n", file_path: path})
    assert :ok = Minga.Buffer.replace_content(parent, "unsaved\n", :user)
    {:ok, view} = ProjectView.overlay(root)
    assert {:ok, "unsaved\n"} = ProjectView.read_file(view, "open.txt")
    assert {:ok, []} = ProjectView.diff(view)
    assert :ok = ProjectView.promote(view, :project_root)
    assert File.read!(path) == "disk\n"
    assert :ok = ProjectView.close(view)
  end

  test "failed fork staging does not install into the parent or lose its draft", %{tmp_dir: root} do
    path = Path.join(root, "open.txt")
    File.write!(path, "original\n")
    parent = start_supervised!({Minga.Buffer.Process, content: "original\n", file_path: path})
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "open.txt", "original\n")
    assert :ok = ProjectView.conditional_mutate(view, "open.txt", token, {:replace, "agent\n"})
    File.mkdir!(Path.join(ProjectView.working_dir(view), "open.txt.__changeset_deleted__"))
    before = :sys.get_state(view.ref.changeset)
    assert {:conflict, _} = ProjectView.promote(view, :project_root)
    assert Minga.Buffer.content(parent) == "original\n"
    assert File.read!(path) == "original\n"
    assert {:ok, "agent\n"} = ProjectView.read_file(view, "open.txt")
    assert :sys.get_state(view.ref.changeset) == before
    close_drafts(view)
  end

  test "publication does not save post-fork unsaved parent changes", %{tmp_dir: root} do
    path = Path.join(root, "open.txt")
    File.write!(path, "one\ntwo\n")
    parent = start_supervised!({Minga.Buffer.Process, content: "one\ntwo\n", file_path: path})
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "open.txt", "one\ntwo\n")

    assert :ok =
             ProjectView.conditional_mutate(view, "open.txt", token, {:edit, [{"one", "ONE"}]})

    assert :ok = Minga.Buffer.replace_content(parent, "one\nTWO\n", :user)
    assert :ok = ProjectView.promote(view, :project_root)
    assert Minga.Buffer.content(parent) == "ONE\nTWO\n"
    assert File.read!(path) == "ONE\ntwo\n"
    assert :ok = ProjectView.close(view)
  end

  test "a file created on disk after staged creation is preserved at publication", %{
    tmp_dir: root
  } do
    {:ok, view} = ProjectView.overlay(root)
    assert :ok = ProjectView.conditional_mutate(view, "new.txt", :absent, {:create, "agent"})
    File.write!(Path.join(root, "new.txt"), "human")
    assert {:conflict, _} = ProjectView.promote(view, :project_root)
    assert File.read!(Path.join(root, "new.txt")) == "human"
    assert {:ok, "agent"} = ProjectView.read_file(view, "new.txt")
    close_drafts(view)
  end

  test "opening a buffer cannot bypass an established changeset draft or deletion", %{
    tmp_dir: root
  } do
    for {backend, create} <- [direct: &ProjectView.direct/1, overlay: &ProjectView.overlay/1],
        {kind, operation, outcome} <- [
          {:replace, {:replace, "draft"}, {:ok, "draft"}},
          {:delete, :delete, {:error, :deleted}}
        ] do
      dir = Path.join(root, "#{backend}-#{kind}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "file.txt")
      File.write!(path, "original")
      {:ok, view} = create.(dir)
      token = revision(view, "file.txt", "original")

      {:ok, %{owner: {:changeset, cs, "file.txt"}}} =
        ProjectView.resolve_source(view, "file.txt")

      assert :ok = ProjectView.conditional_mutate(view, "file.txt", token, operation)

      parent =
        start_supervised!({Minga.Buffer.Process, file_path: path}, id: {backend, kind})

      assert :ok = Minga.Buffer.replace_content(parent, "human unsaved", :user)

      assert {:ok, %{owner: {:changeset, ^cs, "file.txt"}}} =
               ProjectView.resolve_source(view, "file.txt")

      before = :sys.get_state(cs)

      assert {:error, _} =
               ProjectView.conditional_mutate(view, "file.txt", token, {:replace, "stale"})

      assert :sys.get_state(cs) == before
      assert ProjectView.read_file(view, "file.txt") == outcome
      assert Minga.Buffer.content(parent) == "human unsaved"
      assert :ok = ProjectView.promote(view, :project_root)
      assert Minga.Buffer.content(parent) == "human unsaved"

      case kind do
        :replace -> assert File.read!(path) == "draft"
        :delete -> refute File.exists?(path)
      end

      assert :ok = ProjectView.close(view)
    end
  end

  test "a published fork transfers to changeset ownership and remains editable after disk conflict",
       %{tmp_dir: root} do
    path = Path.join(root, "open.txt")
    File.write!(path, "original")
    start_supervised!({Minga.Buffer.Process, file_path: path})
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "open.txt", "original")
    {:ok, %{owner: {:fork, fork}}} = ProjectView.resolve_source(view, "open.txt")
    assert :ok = ProjectView.conditional_mutate(view, "open.txt", token, {:replace, "draft"})
    File.write!(path, "human")
    assert {:conflict, _} = ProjectView.promote(view, :project_root)
    refute Process.alive?(fork)

    assert {:ok, %{owner: {:changeset, _, "open.txt"}}} =
             ProjectView.resolve_source(view, "open.txt")

    assert {:ok, "draft"} = ProjectView.read_file(view, "open.txt")
    token = revision(view, "open.txt", "draft")
    assert :ok = ProjectView.conditional_mutate(view, "open.txt", token, {:replace, "resolved"})
    assert {:ok, "resolved"} = ProjectView.read_file(view, "open.txt")
    assert File.read!(path) == "human"
    close_drafts(view)
  end

  test "partial publication reports a completed deletion and the final failed content outcome",
       %{tmp_dir: root} do
    a = Path.join(root, "a.txt")
    b = Path.join(root, "b.txt")
    File.write!(a, "original a")
    File.write!(b, "original b")
    parent_a = start_supervised!({Minga.Buffer.Process, file_path: a}, id: :parent_a)
    start_supervised!({Minga.Buffer.Process, file_path: b}, id: :parent_b)

    {:ok, view} =
      ProjectView.overlay(root,
        changeset_opts: [
          publication_file_system: Minga.Buffer.ControllableFileSystem,
          publication_opts: [fail_at: :flush]
        ]
      )

    token_a = revision(view, "a.txt", "original a")
    token_b = revision(view, "b.txt", "original b")
    assert :ok = ProjectView.conditional_mutate(view, "a.txt", token_a, :delete)
    assert :ok = ProjectView.conditional_mutate(view, "b.txt", token_b, {:replace, "draft b"})
    assert {:conflict, details} = ProjectView.promote(view, :project_root)
    assert {:ok, "a.txt", :deleted} in details.results
    assert {:error, "b.txt", {:injected, :flush}} in details.results
    assert Enum.count(details.results, &(elem(&1, 1) == "b.txt")) == 1
    refute File.exists?(a)
    assert File.read!(b) == "original b"
    assert Minga.Buffer.content(parent_a) == "original a"
    assert {:error, :enoent} = ProjectView.read_file(view, "a.txt")
    assert {:ok, "draft b"} = ProjectView.read_file(view, "b.txt")
    close_drafts(view)
  end

  test "a dead claimed fork never falls back to the changeset or unchanged disk", %{tmp_dir: root} do
    path = Path.join(root, "open.txt")
    File.write!(path, "original")
    start_supervised!({Minga.Buffer.Process, file_path: path})
    {:ok, view} = ProjectView.overlay(root)
    token = revision(view, "open.txt", "original")
    {:ok, %{owner: {:fork, fork}}} = ProjectView.resolve_source(view, "open.txt")
    GenServer.stop(fork, :normal)
    assert {:error, :owner_unavailable} = ProjectView.resolve_source(view, "open.txt")

    assert {:error, :owner_unavailable} =
             ProjectView.conditional_mutate(view, "open.txt", token, {:replace, "lost"})

    assert File.read!(path) == "original"
    close_drafts(view)
  end

  defp revision(view, path, bytes) do
    {:ok, source} = ProjectView.resolve_source(view, path)
    FileMutation.revision(bytes, nil, {:project_view, source.source_id})
  end

  defp close_drafts(%ProjectView{backend: MingaAgent.ProjectView.Direct, ref: ref} = view) do
    owned = Agent.get(ref, & &1.owned_view)
    :ok = ProjectView.discard(owned)
    :ok = ProjectView.close(view)
  end

  defp close_drafts(view) do
    :ok = ProjectView.discard(view)
    :ok = ProjectView.close(view)
  end
end
