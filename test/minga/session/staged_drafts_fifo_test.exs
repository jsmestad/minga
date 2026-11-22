defmodule Minga.Session.StagedDraftsFifoTest do
  # Creating FIFOs spawns `mkfifo`, an OS process; async OS spawns hit the
  # erl_child_setup EPIPE race.
  use ExUnit.Case, async: false

  alias Minga.Session.StagedDraft
  alias Minga.Session.StagedDrafts
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Overlay
  alias MingaAgent.StagedDraftKeeper
  alias MingaAgent.StagedDraftKeeper.Recovery

  @moduletag :tmp_dir
  @moduletag timeout: 10_000

  defp mkfifo!(path) do
    File.rm(path)
    {_, 0} = System.cmd("mkfifo", [path])
  end

  test "a FIFO in place of a draft file is lost, without blocking the load", %{tmp_dir: dir} do
    opts = [staged_drafts_dir: Path.join(dir, "store")]
    root = Path.join(dir, "project")
    :ok = StagedDrafts.write(root, "v", 1, StagedDraft.new("a", "base", "x"), opts)
    file = StagedDrafts.draft_file(root, "v", "a", opts)
    mkfifo!(file)

    assert {:ok, [%{entries: [{:lost, ^file, _name, :not_a_regular_file}]}]} =
             StagedDrafts.load(root, opts)
  end

  test "a FIFO where a restored file used to be does not block the keeper", %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "base\n")
    registry = :"fifo_views_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    opts = [name: nil, staged_drafts_dir: Path.join(dir, "store"), registry: registry]

    keeper =
      start_supervised!(
        Supervisor.child_spec({StagedDraftKeeper, opts}, id: :first, restart: :temporary)
      )

    {:ok, view} = ProjectView.overlay(root)
    StagedDraftKeeper.persist(keeper, view, 1)
    :ok = ProjectView.write_file(view, "a.txt", "edited\n")
    :sys.get_state(keeper)
    :sys.get_state(keeper)

    changeset = Overlay.changeset_pid(view)
    ref = Process.monitor(changeset)
    stop_supervised!(:first)
    Process.exit(changeset, :shutdown)
    assert_receive {:DOWN, ^ref, :process, _, :shutdown}

    mkfifo!(Path.join(root, "a.txt"))
    fresh = start_supervised!(Supervisor.child_spec({StagedDraftKeeper, opts}, id: :second))
    :ok = StagedDraftKeeper.recover(fresh, root, self())

    assert_receive {:staged_drafts_recovered, ^root, [%Recovery{base_changed: ["a.txt"]}]},
                   5_000
  end
end
