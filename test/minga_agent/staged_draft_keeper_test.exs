defmodule MingaAgent.StagedDraftKeeperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Session.StagedDrafts
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Overlay
  alias MingaAgent.StagedDraftKeeper
  alias MingaAgent.StagedDraftKeeper.Recovery

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "one\ntwo\nthree\n")
    File.write!(Path.join(root, "lib/b.ex"), "alpha\nbeta\n")
    File.write!(Path.join(root, "old.txt"), "remove me\n")

    scope = :"staged_views_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})
    store = [staged_drafts_dir: Path.join(dir, "store"), scope: scope]
    %{root: root, store: store, keeper: start_keeper(store, :first)}
  end

  defp start_keeper(store, id) do
    start_supervised!(
      Supervisor.child_spec({StagedDraftKeeper, [name: nil] ++ store},
        id: id,
        restart: :temporary
      )
    )
  end

  defp stored(root, store) do
    {:ok, views} = StagedDrafts.load(root, store)

    for %{workspace_id: workspace_id, entries: entries} <- views,
        {:ok, _file, draft} <- entries,
        into: %{},
        do: {{workspace_id, draft.path}, draft}
  end

  # Revisions reach the keeper asynchronously and queue one snapshot; poll the
  # observable store instead of assuming message order between processes.
  defp eventually(keeper, check, attempts \\ 500) do
    :sys.get_state(keeper)

    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> eventually(keeper, check, attempts - 1)
    end
  end

  defp stage(view) do
    :ok = ProjectView.write_file(view, "lib/a.ex", "ONE\ntwo\nthree\n")
    :ok = ProjectView.write_file(view, "lib/new.ex", "brand new\n")
    :ok = ProjectView.delete_file(view, "old.txt")
  end

  # The application's shutdown order: the keeper stops before the agent
  # supervisor shuts the changeset down, so the drafts stay on disk.
  defp full_shutdown(view) do
    changeset = Overlay.changeset_pid(view)
    ref = Process.monitor(changeset)
    stop_supervised!(:first)
    Process.exit(changeset, :shutdown)
    assert_receive {:DOWN, ^ref, :process, _, :shutdown}
  end

  describe "Editor restart" do
    test "a staged view outlives the Editor that owned it and is recovered live",
         %{root: root, keeper: keeper} do
      test_pid = self()

      editor =
        spawn(fn ->
          {:ok, view} = ProjectView.overlay(root)
          :ok = ProjectView.write_file(view, "lib/a.ex", "ONE\ntwo\nthree\n")
          StagedDraftKeeper.persist(keeper, view, 4)
          send(test_pid, {:view, view})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:view, view}, 2_000
      ref = Process.monitor(editor)
      Process.exit(editor, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}

      # The changeset and fork store are not linked to the Editor.
      assert ProjectView.active?(view)

      :ok = StagedDraftKeeper.recover(keeper, root, self())

      assert_receive {:staged_drafts_recovered, ^root,
                      [%Recovery{source: :live, workspace_id: 4, view: ^view, changes: changes}]},
                     2_000

      assert [%{path: "lib/a.ex"}] = changes

      assert ProjectView.promote(view, :project_root) == :ok
      assert File.read!(Path.join(root, "lib/a.ex")) == "ONE\ntwo\nthree\n"
    end
  end

  describe "persistence" do
    test "every staged change is saved, and a publish deletes the saved drafts",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      stage(view)

      eventually(keeper, fn -> map_size(stored(root, store)) == 3 end)
      drafts = stored(root, store)
      assert drafts[{1, "lib/a.ex"}].base == "one\ntwo\nthree\n"
      assert drafts[{1, "lib/a.ex"}].content == "ONE\ntwo\nthree\n"
      assert drafts[{1, "lib/new.ex"}].base == nil
      assert drafts[{1, "old.txt"}].content == :deleted

      ref = Process.monitor(Overlay.changeset_pid(view))
      assert ProjectView.promote(view, :project_root) == :ok
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
      eventually(keeper, fn -> stored(root, store) == %{} end)
    end

    test "discarding deletes the saved drafts", %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      stage(view)
      eventually(keeper, fn -> map_size(stored(root, store)) == 3 end)

      ref = Process.monitor(Overlay.changeset_pid(view))
      assert ProjectView.discard(view) == :ok
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
      eventually(keeper, fn -> stored(root, store) == %{} end)
    end

    test "dropping one staged file removes only its saved draft",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      stage(view)
      eventually(keeper, fn -> map_size(stored(root, store)) == 3 end)

      :ok = ProjectView.discard_file(view, "lib/new.ex")

      eventually(keeper, fn ->
        Map.keys(stored(root, store)) |> Enum.sort() == [{1, "lib/a.ex"}, {1, "old.txt"}]
      end)
    end

    test "a draft in an open buffer's fork is saved", %{root: root, store: store, keeper: keeper} do
      path = Path.join(root, "lib/b.ex")
      start_supervised!({BufferProcess, content: File.read!(path), file_path: path})
      {:ok, view} = ProjectView.overlay(root)
      :ok = ProjectView.write_file(view, "lib/b.ex", "alpha\nBETA\n")
      assert {:ok, %{owner: {:fork, _}}} = ProjectView.resolve_source(view, "lib/b.ex")

      StagedDraftKeeper.persist(keeper, view, 1)
      :sys.get_state(keeper)

      assert %{{1, "lib/b.ex"} => %{base: "alpha\nbeta\n", content: "alpha\nBETA\n"}} =
               stored(root, store)
    end

    test "moving a view to another workspace moves its drafts",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      :ok = ProjectView.write_file(view, "lib/a.ex", "ONE\n")
      StagedDraftKeeper.persist(keeper, view, 1)
      StagedDraftKeeper.persist(keeper, view, 2)
      :sys.get_state(keeper)

      assert Map.keys(stored(root, store)) == [{2, "lib/a.ex"}]
    end
  end

  describe "full restart" do
    test "saved drafts are rebuilt into a new view that publishes them",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      stage(view)
      eventually(keeper, fn -> map_size(stored(root, store)) == 3 end)
      full_shutdown(view)

      fresh = start_keeper(store, :second)
      :ok = StagedDraftKeeper.recover(fresh, root, self())

      assert_receive {:staged_drafts_recovered, ^root, [%Recovery{} = recovery]}, 2_000
      assert %Recovery{source: :disk, workspace_id: 1, base_changed: [], lost: []} = recovery

      assert recovery.changes |> Enum.map(& &1.path) |> Enum.sort() ==
               ["lib/a.ex", "lib/new.ex", "old.txt"]

      assert ProjectView.read_file(recovery.view, "lib/a.ex") == {:ok, "ONE\ntwo\nthree\n"}

      ref = Process.monitor(Overlay.changeset_pid(recovery.view))
      assert ProjectView.promote(recovery.view, :project_root) == :ok
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000
      assert File.read!(Path.join(root, "lib/a.ex")) == "ONE\ntwo\nthree\n"
      assert File.read!(Path.join(root, "lib/new.ex")) == "brand new\n"
      refute File.exists?(Path.join(root, "old.txt"))
      eventually(fresh, fn -> stored(root, store) == %{} end)
    end

    test "a file changed on disk since staging is reported, then merged or kept as a conflict",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      :ok = ProjectView.write_file(view, "lib/a.ex", "ONE\ntwo\nthree\n")
      :ok = ProjectView.write_file(view, "lib/b.ex", "alpha\nBETA\n")
      eventually(keeper, fn -> map_size(stored(root, store)) == 2 end)
      full_shutdown(view)

      # Someone edits both files while Minga is not running: one change does
      # not overlap the staged edit, the other does.
      File.write!(Path.join(root, "lib/a.ex"), "one\ntwo\nTHREE\n")
      File.write!(Path.join(root, "lib/b.ex"), "alpha\nbeta-human\n")

      fresh = start_keeper(store, :second)
      :ok = StagedDraftKeeper.recover(fresh, root, self())
      assert_receive {:staged_drafts_recovered, ^root, [%Recovery{} = recovery]}, 2_000
      assert Enum.sort(recovery.base_changed) == ["lib/a.ex", "lib/b.ex"]

      assert {:conflict, %{conflicts: [{:conflict, "lib/b.ex", :concurrent_edit}]}} =
               ProjectView.promote(recovery.view, :project_root)

      assert File.read!(Path.join(root, "lib/a.ex")) == "ONE\ntwo\nTHREE\n"
      assert File.read!(Path.join(root, "lib/b.ex")) == "alpha\nbeta-human\n"

      # The conflicting draft stays staged and saved.
      eventually(fresh, fn -> Map.keys(stored(root, store)) == [{1, "lib/b.ex"}] end)
    end

    test "an unreadable draft is reported lost by name and the others are restored",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      stage(view)
      eventually(keeper, fn -> map_size(stored(root, store)) == 3 end)
      full_shutdown(view)

      file = StagedDrafts.draft_file(root, view.id, "lib/new.ex", store)

      File.write!(
        file,
        file |> File.read!() |> JSON.decode!() |> Map.put("content", "%%") |> JSON.encode!()
      )

      fresh = start_keeper(store, :second)
      :ok = StagedDraftKeeper.recover(fresh, root, self())

      assert_receive {:staged_drafts_recovered, ^root, [%Recovery{} = recovery]}, 2_000
      assert recovery.lost == [{"lib/new.ex", :invalid_format}]
      assert recovery.changes |> Enum.map(& &1.path) |> Enum.sort() == ["lib/a.ex", "old.txt"]
      refute File.exists?(file)
    end

    test "nothing is offered when nothing was staged", %{root: root, keeper: keeper} do
      :ok = StagedDraftKeeper.recover(keeper, root, self())
      :sys.get_state(keeper)
      refute_received {:staged_drafts_recovered, _, _}
    end
  end

  describe "keeper restart" do
    test "a restarted keeper adopts live views: publishing still deletes their drafts and new edits are saved",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      :ok = ProjectView.write_file(view, "lib/a.ex", "ONE\ntwo\nthree\n")
      eventually(keeper, fn -> map_size(stored(root, store)) == 1 end)

      ref = Process.monitor(keeper)
      Process.exit(keeper, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      restarted = start_keeper(store, :restarted)
      :sys.get_state(restarted)

      :ok = ProjectView.write_file(view, "lib/b.ex", "alpha\nBETA\n")
      eventually(restarted, fn -> map_size(stored(root, store)) == 2 end)

      changeset = Process.monitor(Overlay.changeset_pid(view))
      assert ProjectView.promote(view, :project_root) == :ok
      assert_receive {:DOWN, ^changeset, :process, _, :normal}, 2_000
      eventually(restarted, fn -> stored(root, store) == %{} end)
    end
  end

  describe "two views for one workspace" do
    test "a new view for an occupied workspace never deletes the other view's drafts",
         %{root: root, store: store, keeper: keeper} do
      {:ok, surviving} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, surviving, 4)
      :ok = ProjectView.write_file(surviving, "lib/a.ex", "ONE\ntwo\nthree\n")
      eventually(keeper, fn -> map_size(stored(root, store)) == 1 end)

      # The restarted Editor gives workspace 4 a fresh, empty staging area.
      {:ok, fresh} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, fresh, 4)
      :sys.get_state(keeper)

      assert Map.keys(stored(root, store)) == [{4, "lib/a.ex"}]

      :ok = StagedDraftKeeper.recover(keeper, root, self())

      assert_receive {:staged_drafts_recovered, ^root,
                      [%Recovery{source: :live, view: ^surviving}]},
                     2_000
    end
  end

  describe "restore failures" do
    test "a draft that cannot be read now keeps every draft of its view on disk",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      stage(view)
      eventually(keeper, fn -> map_size(stored(root, store)) == 3 end)
      full_shutdown(view)

      unreadable = StagedDrafts.draft_file(root, view.id, "lib/a.ex", store)
      File.chmod!(unreadable, 0o000)
      on_exit(fn -> File.chmod(unreadable, 0o600) end)

      fresh = start_keeper(store, :second)
      :ok = StagedDraftKeeper.recover(fresh, root, self())

      assert_receive {:staged_drafts_recovered, ^root, [%Recovery{view: nil} = recovery]}, 2_000
      assert recovery.lost == []

      assert recovery.retained |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               ["lib/new.ex", "old.txt", Path.basename(unreadable)] |> Enum.sort()

      File.chmod!(unreadable, 0o600)
      assert map_size(stored(root, store)) == 3
    end
  end

  describe "oversized drafts" do
    test "a draft that grows past the limit is reported lost after a restart, never restored stale",
         %{root: root, store: store} do
      small = Keyword.put(store, :max_file_bytes, 32)
      keeper = start_keeper(small, :small)
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)

      :ok = ProjectView.write_file(view, "lib/a.ex", "small edit\n")
      eventually(keeper, fn -> match?(%{{1, "lib/a.ex"} => _}, stored(root, store)) end)

      big = String.duplicate("grown past the limit\n", 10)
      :ok = ProjectView.write_file(view, "lib/a.ex", big)
      eventually(keeper, fn -> stored(root, store) == %{} end)

      file = StagedDrafts.draft_file(root, view.id, "lib/a.ex", store)
      marker = File.read!(file)
      refute marker =~ Base.encode64("small edit\n")
      refute marker =~ "grown"

      changeset = Overlay.changeset_pid(view)
      ref = Process.monitor(changeset)
      stop_supervised!(:small)
      Process.exit(changeset, :shutdown)
      assert_receive {:DOWN, ^ref, :process, _, :shutdown}

      fresh = start_keeper(small, :fresh)
      :ok = StagedDraftKeeper.recover(fresh, root, self())

      assert_receive {:staged_drafts_recovered, ^root, [%Recovery{} = recovery]}, 2_000
      assert recovery.view == nil
      assert recovery.lost == [{"lib/a.ex", :too_large}]
      refute File.exists?(file)
    end
  end

  describe "failed saves" do
    test "a save that fails is retried without waiting for another staged change",
         %{root: root, store: store} do
      keeper = start_keeper(Keyword.put(store, :retry_ms, 60_000), :retrying)
      {:ok, view} = ProjectView.overlay(root)

      :ok = ProjectView.write_file(view, "lib/a.ex", "ONE\ntwo\nthree\n")

      # A directory where the draft file belongs makes the save fail.
      blocker = StagedDrafts.draft_file(root, view.id, "lib/a.ex", store)
      File.mkdir_p!(Path.join(blocker, "occupied"))

      StagedDraftKeeper.persist(keeper, view, 1)
      :sys.get_state(keeper)
      assert stored(root, store) == %{}

      # The keeper's retry state is the behavior under test here.
      assert %{retry_pending: true, written: %{"lib/a.ex" => nil}} =
               :sys.get_state(keeper).tracked[view.id]

      # The failed save scheduled a retry. Clear the obstacle, then deliver
      # the retry timer's message instead of waiting for it.
      File.rm_rf!(blocker)
      send(keeper, {:retry_snapshot, view.id})

      eventually(keeper, fn -> match?(%{{1, "lib/a.ex"} => _}, stored(root, store)) end)
    end
  end

  describe "failed cleanup after a publish" do
    # A view directory without write permission makes the deletion fail.
    defp block_cleanup(root, view, store) do
      dir = StagedDrafts.view_dir(root, view.id, store)
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod(dir, 0o700) end)
      dir
    end

    defp publish_and_wait_for_retirement(keeper, root, store, view) do
      ref = Process.monitor(Overlay.changeset_pid(view))
      assert ProjectView.promote(view, :project_root) == :ok
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 2_000

      eventually(keeper, fn ->
        match?({:ok, [%{retired: true}]}, StagedDrafts.load(root, store))
      end)
    end

    test "is retried until it succeeds, warning once, and the view is not offered meanwhile",
         %{root: root, store: store} do
      keeper = start_keeper(Keyword.put(store, :retry_ms, 60_000), :retrying)
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      :ok = ProjectView.write_file(view, "lib/a.ex", "ONE\ntwo\nthree\n")
      eventually(keeper, fn -> map_size(stored(root, store)) == 1 end)
      dir = block_cleanup(root, view, store)

      log =
        capture_log(fn ->
          publish_and_wait_for_retirement(keeper, root, store, view)

          # The retry timer's message, delivered instead of waited for, fails
          # again without a second warning.
          send(keeper, {:retry_delete, dir})
          :sys.get_state(keeper)
        end)

      assert log |> String.split("could not be cleaned up") |> length() == 2

      :ok = StagedDraftKeeper.recover(keeper, root, self())
      :sys.get_state(keeper)
      refute_received {:staged_drafts_recovered, _, _}

      File.chmod!(dir, 0o700)
      send(keeper, {:retry_delete, dir})

      eventually(keeper, fn -> StagedDrafts.load(root, store) == {:ok, []} end)
      refute File.exists?(dir)
    end

    test "is not offered at the next start, which finishes the cleanup",
         %{root: root, store: store, keeper: keeper} do
      {:ok, view} = ProjectView.overlay(root)
      StagedDraftKeeper.persist(keeper, view, 1)
      stage(view)
      eventually(keeper, fn -> map_size(stored(root, store)) == 3 end)
      dir = block_cleanup(root, view, store)

      publish_and_wait_for_retirement(keeper, root, store, view)
      stop_supervised!(:first)
      File.chmod!(dir, 0o700)

      fresh = start_keeper(store, :second)
      :ok = StagedDraftKeeper.recover(fresh, root, self())
      :sys.get_state(fresh)

      refute_received {:staged_drafts_recovered, _, _}
      assert StagedDrafts.load(root, store) == {:ok, []}
      refute File.exists?(dir)
    end
  end
end
