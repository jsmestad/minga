defmodule MingaEditor.FileTree.FreshnessTest do
  @moduledoc "Tests for file tree freshness git-cache integration."
  use ExUnit.Case, async: true

  alias Minga.Events
  alias Minga.Git.Repo
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.Freshness

  @moduletag :tmp_dir

  test "cache refresh starts a Git.Repo owner when no cache exists yet", %{tmp_dir: dir} do
    events_registry = start_events_registry()
    entry = %StatusEntry{path: "lib/foo.ex", status: :modified, staged: false}
    GitStub.set_root(dir, dir)
    GitStub.set_status(dir, [entry])

    on_exit(fn ->
      GitStub.clear(dir)
      stop_repo(dir)
    end)

    tree = FileTree.new(dir)

    assert %FileTree{} = Freshness.refresh_tree_git_status_from_cache(tree, events_registry)
    assert repo = Repo.lookup(dir)

    Repo.await_refresh(repo)
    assert Repo.status(repo) == [entry]
  end

  @spec start_events_registry() :: atom()
  defp start_events_registry do
    name = :"file_tree_events_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Events, name: name}, id: {Events, name})
    name
  end

  @spec stop_repo(String.t()) :: :ok
  defp stop_repo(git_root) do
    case Repo.lookup(git_root) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Minga.Git.Repo.Supervisor, pid)
    end
  catch
    :exit, _ -> :ok
  end
end
